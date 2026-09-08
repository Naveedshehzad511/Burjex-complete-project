"""
MT5 Web API protocol layer — Python implementation of the MT5 Manager Web API.

Based on: MetaTrader5SDK/Examples/Web/PHP/mt5_api/
  - mt5_protocol.php  → header format, command names, param keys
  - mt5_connect.php   → TCP socket, packet read/write, AES stream
  - mt5_auth.php      → AUTH_START / AUTH_ANSWER challenge-response
  - mt5_user.php      → USER_GET, USER_ACCOUNT_GET, USER_ADD, USER_DEPOSIT_CHANGE
  - mt5_common.php    → COMMON_GET
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import secrets
import socket
import struct
from typing import Optional

logger = logging.getLogger(__name__)

# ─────────────────────────────────────────────────────────────────────────────
# Protocol constants (from mt5_protocol.php)
# ─────────────────────────────────────────────────────────────────────────────
WEBAPI_VERSION = "3950"
WEBAPI_AGENT   = "BurjexCRM/1.0"
WEBAPI_WORD    = "WebAPI"

HEADER_LEN     = 9      # 4+4+1 hex chars
MAX_CLIENT_CMD = 16383  # client seq number upper bound (0x3FFF)

# Packet header format strings (from mt5_connect.php)
FIRST_PACKET_PREFIX = "MT5WEBAPI"
PACKET_FORMAT       = "{size:04x}{seq:04x}"  # used from 2nd request onward

# Commands
CMD_AUTH_START   = "AUTH_START"
CMD_AUTH_ANSWER  = "AUTH_ANSWER"
CMD_COMMON_GET   = "COMMON_GET"
CMD_TIME_SERVER  = "TIME_SERVER"
CMD_USER_GET     = "USER_GET"
CMD_USER_ADD     = "USER_ADD"
CMD_USER_UPDATE  = "USER_UPDATE"
CMD_USER_DELETE  = "USER_DELETE"
CMD_USER_ACCOUNT_GET    = "USER_ACCOUNT_GET"
CMD_USER_LOGINS         = "USER_LOGINS"
CMD_USER_PASS_CHECK     = "USER_PASS_CHECK"
CMD_USER_PASS_CHANGE    = "USER_PASS_CHANGE"
CMD_USER_DEPOSIT_CHANGE = "USER_DEPOSIT_CHANGE"
CMD_PING = "PING"

# Parameter names
P_VERSION       = "VERSION"
P_AGENT         = "AGENT"
P_LOGIN         = "LOGIN"
P_TYPE          = "TYPE"
P_CRYPT_METHOD  = "CRYPT_METHOD"
P_SRV_RAND      = "SRV_RAND"
P_SRV_RAND_ANS  = "SRV_RAND_ANSWER"
P_CLI_RAND      = "CLI_RAND"
P_CLI_RAND_ANS  = "CLI_RAND_ANSWER"
P_CRYPT_RAND    = "CRYPT_RAND"
P_RETCODE       = "RETCODE"
P_BALANCE       = "BALANCE"
P_COMMENT       = "COMMENT"
P_GROUP         = "GROUP"
P_PASS_MAIN     = "PASS_MAIN"
P_PASS_INVESTOR = "PASS_INVESTOR"
P_NAME          = "NAME"
P_LEVERAGE      = "LEVERAGE"
P_RIGHTS        = "RIGHTS"
P_BODY_TEXT     = "BODY_TEXT"

CRYPT_NONE      = "NONE"
CRYPT_AES256OFB = "AES256OFB"

# MT_RET codes (subset from mt5_retcode.php / MT5APIConstants.h)
MT_RET_OK              = 0
MT_RET_OK_NONE         = 1
MT_RET_ERR_NETWORK     = 7
MT_RET_ERR_TIMEOUT     = 9
MT_RET_ERR_CONNECTION  = 10
MT_RET_ERR_PARAMS      = 3
MT_RET_ERR_DATA        = 4
MT_RET_AUTH_SERVER_BAD = 1008
MT_RET_REPORT_NODATA   = 5003


# ─────────────────────────────────────────────────────────────────────────────
# Exceptions
# ─────────────────────────────────────────────────────────────────────────────
class MT5ConnectionError(Exception):
    """Raised when the TCP connection to the MT5 server fails."""


class MT5AuthError(Exception):
    """Raised when authentication with the MT5 manager account fails."""


class MT5APIError(Exception):
    """Raised when the MT5 server returns a non-zero retcode."""

    def __init__(self, retcode: int, message: str = ""):
        self.retcode = retcode
        super().__init__(f"MT5 retcode {retcode}: {message}")


# ─────────────────────────────────────────────────────────────────────────────
# Helpers: MD5 hashing (mirrors MTUtils in PHP)
# ─────────────────────────────────────────────────────────────────────────────
def _md5_bytes(data: bytes) -> bytes:
    return hashlib.md5(data).digest()


def _hex_to_bytes(hex_str: str) -> bytes:
    """Convert hex string to raw bytes (mirrors MTUtils::GetFromHex)."""
    return bytes.fromhex(hex_str)


def _password_hash(password: str, rand_bytes: bytes) -> str:
    """
    Compute the AUTH password hash — exactly mirrors MTUtils::GetHashFromPassword in mt5_utils.php:

      $password_hash = md5(mb_convert_encoding($password, 'utf-16le', 'utf-8'), true) . WEB_API_WORD;
      $hash = md5(md5($password_hash, true) . $rand_code);

    Step 1: inner1 = md5(password as UTF-16LE) → 16 raw bytes
    Step 2: inner2 = md5(inner1 + b"WebAPI")   → 16 raw bytes
    Step 3: outer  = md5(inner2 + rand_bytes)  → lowercase hex string
    """
    inner1 = _md5_bytes(password.encode("utf-16-le"))
    inner2 = _md5_bytes(inner1 + WEBAPI_WORD.encode("ascii"))
    outer  = _md5_bytes(inner2 + rand_bytes)
    return outer.hex()


# ─────────────────────────────────────────────────────────────────────────────
# AES-256-OFB stream cipher (mirrors MT5CryptAes256 + xor loop in mt5_connect.php)
#
# The SDK uses AES-256 in OFB mode as a keystream generator: it encrypts a
# 16-byte IV block repeatedly to produce a XOR keystream applied byte-by-byte.
# Python's cryptography library makes this straightforward.
# ─────────────────────────────────────────────────────────────────────────────
try:
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    from cryptography.hazmat.backends import default_backend
    _HAS_CRYPTO = True
except ImportError:  # pragma: no cover
    _HAS_CRYPTO = False


class _AES256OFBStream:
    """Stateful AES-256-OFB XOR keystream (mirrors CryptPacket / DeCryptPacket in PHP)."""

    def __init__(self, key: bytes, iv: bytes) -> None:
        if not _HAS_CRYPTO:
            raise RuntimeError("cryptography package is required for AES encryption")
        # We need to encrypt the IV block in ECB mode repeatedly (OFB keystream).
        self._cipher = Cipher(
            algorithms.AES(key),
            modes.ECB(),  # noqa: S305 – OFB keystream via repeated ECB blocks
            backend=default_backend(),
        )
        self._block = iv          # current OFB state block (16 bytes)
        self._keystream = b""     # buffered keystream bytes not yet consumed

    def _refill(self) -> None:
        enc = self._cipher.encryptor()
        self._block = enc.update(self._block) + enc.finalize()
        self._keystream += self._block

    def encrypt(self, data: bytes) -> bytes:
        out = bytearray()
        for b in data:
            if not self._keystream:
                self._refill()
            out.append(b ^ self._keystream[0])
            self._keystream = self._keystream[1:]
        return bytes(out)

    # Decryption == encryption for OFB
    decrypt = encrypt


# ─────────────────────────────────────────────────────────────────────────────
# Low-level packet I/O (mirrors MTConnect in PHP)
# ─────────────────────────────────────────────────────────────────────────────
def _recv_exactly(sock: socket.socket, n: int) -> bytes:
    """Block until exactly n bytes are received."""
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise MT5ConnectionError("Connection closed by MT5 server during recv")
        buf += chunk
    return buf


def _read_packet(sock: socket.socket) -> tuple[int, int, int, bytes]:
    """
    Read one packet from the socket.

    Header layout (9 ASCII chars, all hex):
      [0:4]  body_size  (4 hex chars)
      [4:8]  seq_number (4 hex chars)
      [8:9]  flag       (1 hex char;  0 = last fragment, 1 = more follow)

    Returns: (body_size, seq_number, flag, body_bytes)
    """
    header_raw = _recv_exactly(sock, HEADER_LEN)
    header_str = header_raw.decode("ascii")
    body_size   = int(header_str[0:4], 16)
    seq_number  = int(header_str[4:8], 16)
    flag        = int(header_str[8:9], 16)
    body        = _recv_exactly(sock, body_size) if body_size else b""
    return body_size, seq_number, flag, body


def _write_packet(
    sock: socket.socket,
    command: str,
    params: dict,
    seq: int,
    first: bool,
    aes_out: Optional["_AES256OFBStream"] = None,
) -> None:
    """
    Encode and send one packet.

    Packet body (UTF-16LE):
      COMMAND|PARAM1=VALUE1|PARAM2=VALUE2|\r\n[JSON_BODY]
    """
    body_text = command + "|"
    json_body = ""
    for k, v in params.items():
        if k == P_BODY_TEXT:
            json_body = str(v)
        else:
            # Escape pipe chars in values
            body_text += f"{k}={str(v).replace('|', '')}|"
    body_text += "\r\n"
    if json_body:
        body_text += json_body

    body_utf16 = body_text.encode("utf-16-le")

    # Encrypt after auth (not for AUTH_START or AUTH_ANSWER)
    if aes_out and command not in (CMD_AUTH_START, CMD_AUTH_ANSWER):
        body_utf16 = aes_out.encrypt(body_utf16)

    size_hex = f"{len(body_utf16):04x}"
    seq_hex  = f"{seq:04x}"

    if first:
        header = f"{FIRST_PACKET_PREFIX}{size_hex}{seq_hex}".encode("ascii")
    else:
        header = f"{size_hex}{seq_hex}".encode("ascii")

    flag_byte = b"0"  # always single fragment from client
    sock.sendall(header + flag_byte + body_utf16)


def _parse_response(
    raw_utf16: bytes,
    aes_in: Optional["_AES256OFBStream"] = None,
    is_auth: bool = False,
) -> tuple[str, dict, Optional[dict]]:
    """
    Parse a received response body.

    Returns: (command, params_dict, json_payload_or_None)
    """
    if aes_in and not is_auth:
        raw_utf16 = aes_in.decrypt(raw_utf16)

    text = raw_utf16.decode("utf-16-le", errors="replace")

    # Split at \r\n to separate header line from JSON body
    if "\r\n" in text:
        header_line, remainder = text.split("\r\n", 1)
    else:
        header_line = text
        remainder = ""

    parts = header_line.split("|")
    command = parts[0] if parts else ""
    params: dict = {}
    for part in parts[1:]:
        if "=" in part:
            k, v = part.split("=", 1)
            params[k.upper()] = v

    json_payload = None
    body_str = remainder.strip()
    if body_str:
        try:
            json_payload = json.loads(body_str)
        except json.JSONDecodeError:
            pass

    return command, params, json_payload


def _get_retcode(params: dict) -> int:
    rc_str = params.get(P_RETCODE, "-1")
    try:
        return int(str(rc_str).split()[0])
    except (ValueError, AttributeError):
        return -1


# ─────────────────────────────────────────────────────────────────────────────
# Main client
# ─────────────────────────────────────────────────────────────────────────────
import threading

class MT5Client:
    """
    Stateful MT5 Manager Web API client.

    Usage (context manager recommended):

        with MT5Client(host, port, login, password) as client:
            info = client.user_account_get(login_id)
    """
    _thread_lock = threading.Lock()

    def __init__(
        self,
        host: str,
        port: int,
        login: int,
        password: str,
        timeout: float = 10.0,
        use_encryption: bool = False,
    ) -> None:
        self._host = host
        self._port = port
        self._login = int(login)
        self._password = password
        self._timeout = timeout
        self._use_encryption = use_encryption

        self._sock: Optional[socket.socket] = None
        self._seq: int = 0
        self._first: bool = True
        self._aes_out: Optional[_AES256OFBStream] = None
        self._aes_in:  Optional[_AES256OFBStream] = None
        self._lock_file = None

    # ── lifecycle ─────────────────────────────────────────────────────────────

    def connect(self) -> "MT5Client":
        """Open TCP connection and authenticate. Returns self for chaining."""
        # Serialize MT5 API use across threads. Always release via disconnect()
        # if anything fails after acquire — otherwise Group Management / other
        # callers deadlock forever on the next connect().
        self._thread_locked = self._thread_lock.acquire(blocking=True)
        try:
            # fcntl is Unix-only; on Windows skip cross-process file lock.
            try:
                import fcntl  # type: ignore
            except ImportError:
                fcntl = None  # type: ignore

            lock_file_path = os.path.join(
                os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                "storage",
                "mt5_lock.lock",
            )
            if fcntl is not None:
                try:
                    os.makedirs(os.path.dirname(lock_file_path), exist_ok=True)
                    self._lock_file = open(lock_file_path, "w")
                    fcntl.flock(self._lock_file, fcntl.LOCK_EX)
                except Exception as e:
                    logger.warning("MT5 Client failed to acquire file lock: %s", e)

            try:
                self._sock = socket.create_connection(
                    (self._host, self._port), timeout=self._timeout
                )
            except OSError as exc:
                raise MT5ConnectionError(
                    f"Cannot connect to MT5 server at {self._host}:{self._port}: {exc}"
                ) from exc
            self._seq = 0
            self._first = True
            self._auth()
            return self
        except Exception:
            self.disconnect()
            raise

    def disconnect(self) -> None:
        """Close the TCP connection and release locks."""
        if self._sock:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        if self._lock_file:
            try:
                try:
                    import fcntl  # type: ignore
                    fcntl.flock(self._lock_file, fcntl.LOCK_UN)
                except ImportError:
                    pass
                self._lock_file.close()
            except Exception:
                pass
            self._lock_file = None
        if getattr(self, "_thread_locked", False):
            try:
                self._thread_lock.release()
            except RuntimeError:
                pass
            self._thread_locked = False

    def __enter__(self) -> "MT5Client":
        return self.connect()

    def __exit__(self, *_) -> None:
        self.disconnect()

    # ── internal send/receive helpers ────────────────────────────────────────

    def _next_seq(self) -> int:
        self._seq = (self._seq % MAX_CLIENT_CMD) + 1
        return self._seq

    def _send(self, command: str, params: dict, is_auth: bool = False) -> None:
        assert self._sock, "Not connected"
        seq = self._next_seq()
        aes = None if is_auth else self._aes_out
        _write_packet(self._sock, command, params, seq, self._first, aes)
        self._first = False

    def _recv(self, is_auth: bool = False) -> tuple[str, dict, Optional[dict]]:
        """Read packet(s) until flag==0 (last fragment)."""
        assert self._sock, "Not connected"
        accumulated = b""
        while True:
            _body_size, _seq, flag, body = _read_packet(self._sock)
            accumulated += body
            if flag == 0:
                break
        aes = None if is_auth else self._aes_in
        return _parse_response(accumulated, aes, is_auth)

    def _call(self, command: str, params: dict) -> tuple[dict, Optional[dict]]:
        """
        Send command and receive response.
        Returns (header_params, json_payload).
        Raises MT5APIError if retcode != 0.
        """
        self._send(command, params)
        resp_cmd, resp_params, resp_json = self._recv()
        if resp_cmd != command:
            raise MT5APIError(-1, f"Unexpected response command: {resp_cmd!r} (expected {command!r})")
        rc = _get_retcode(resp_params)
        if rc != MT_RET_OK and rc != MT_RET_OK_NONE:
            raise MT5APIError(rc, f"Command {command} failed")
        return resp_params, resp_json

    # ── authentication (AUTH_START → AUTH_ANSWER) ────────────────────────────

    def _auth(self) -> None:
        """
        Perform the two-step challenge-response authentication.
        Mirrors MTAuthProtocol::Auth() in mt5_auth.php.
        """
        assert self._sock, "Not connected"

        logger.debug(
            "[MT5 AUTH] Starting authentication | login=%s | use_encryption=%s | "
            "password_length=%d | version=%s | agent=%s",
            self._login,
            self._use_encryption,
            len(self._password),
            WEBAPI_VERSION,
            WEBAPI_AGENT,
        )

        # Step 1: AUTH_START
        auth_start_params = {
            P_VERSION:      WEBAPI_VERSION,
            P_AGENT:        WEBAPI_AGENT,
            P_LOGIN:        self._login,
            P_TYPE:         "MANAGER",
            P_CRYPT_METHOD: CRYPT_AES256OFB if self._use_encryption else CRYPT_NONE,
        }
        logger.debug("[MT5 AUTH] Sending AUTH_START | params=%s", auth_start_params)
        self._send(CMD_AUTH_START, auth_start_params, is_auth=True)

        _, start_params, _ = self._recv(is_auth=True)
        rc = _get_retcode(start_params)
        logger.debug("[MT5 AUTH] AUTH_START response | retcode=%s | all_params=%s", rc, start_params)

        if rc != MT_RET_OK:
            logger.error("[MT5 AUTH] AUTH_START rejected | retcode=%s", rc)
            raise MT5AuthError(f"AUTH_START failed with retcode {rc}")

        srv_rand_hex = start_params.get(P_SRV_RAND, "")
        logger.debug("[MT5 AUTH] Server random (SRV_RAND) | hex=%s | length=%d",
                     srv_rand_hex, len(srv_rand_hex))

        if not srv_rand_hex or srv_rand_hex == "none":
            logger.error("[MT5 AUTH] Server did not return SRV_RAND in AUTH_START response")
            raise MT5AuthError("AUTH_START: server did not return SRV_RAND")

        srv_rand_bytes = _hex_to_bytes(srv_rand_hex)
        logger.debug("[MT5 AUTH] SRV_RAND decoded | byte_length=%d", len(srv_rand_bytes))

        # Compute password hash for server
        srv_hash = _password_hash(self._password, srv_rand_bytes)
        logger.debug("[MT5 AUTH] Computed SRV_RAND_ANSWER hash | hash=%s", srv_hash)

        # Our random challenge
        cli_rand_hex = secrets.token_hex(16)
        logger.debug("[MT5 AUTH] Generated CLI_RAND | hex=%s", cli_rand_hex)

        # Step 2: AUTH_ANSWER
        auth_answer_params = {
            P_SRV_RAND_ANS: srv_hash,
            P_CLI_RAND:     cli_rand_hex,
        }
        logger.debug("[MT5 AUTH] Sending AUTH_ANSWER | params=%s", auth_answer_params)
        self._send(CMD_AUTH_ANSWER, auth_answer_params, is_auth=True)

        _, ans_params, _ = self._recv(is_auth=True)
        rc = _get_retcode(ans_params)
        logger.debug("[MT5 AUTH] AUTH_ANSWER response | retcode=%s | all_params=%s", rc, ans_params)

        if rc != MT_RET_OK:
            logger.error(
                "[MT5 AUTH] AUTH_ANSWER rejected | retcode=%s | "
                "This usually means: wrong password, manager-API not enabled, or IP not whitelisted.",
                rc,
            )
            raise MT5AuthError(f"AUTH_ANSWER failed with retcode {rc}")

        # Verify server's knowledge of our password (mirrors hash check in PHP)
        cli_rand_bytes = _hex_to_bytes(cli_rand_hex)
        expected_cli_hash = _password_hash(self._password, cli_rand_bytes)
        got_cli_hash = ans_params.get(P_CLI_RAND_ANS, "")
        logger.debug(
            "[MT5 AUTH] CLI_RAND_ANSWER verification | expected=%s | got=%s | match=%s",
            expected_cli_hash, got_cli_hash, expected_cli_hash == got_cli_hash,
        )
        if expected_cli_hash != got_cli_hash:
            raise MT5AuthError("AUTH_ANSWER: server password hash mismatch — untrusted server?")

        # Setup AES streams if encryption is requested
        if self._use_encryption and _HAS_CRYPTO:
            crypt_rand_hex = ans_params.get(P_CRYPT_RAND, "")
            logger.debug("[MT5 AUTH] Setting up AES encryption | crypt_rand_length=%d", len(crypt_rand_hex))
            if crypt_rand_hex:
                self._setup_aes(crypt_rand_hex)

        logger.info("[MT5 AUTH] Authentication successful | login=%s", self._login)

    def _setup_aes(self, crypt_rand_hex: str) -> None:
        """
        Derive AES key + IVs from crypt_rand (mirrors MTConnect::SetCryptRand in PHP).
        The PHP derives 16 md5 rounds from the server's crypt_rand merged with the
        password hash; indices [0]+[1] = key, [2] = IV_out, [3] = IV_in.
        """
        # password_md5 = md5(password as utf-16le, raw)
        pwd_md5 = _md5_bytes(self._password.encode("utf-16-le"))
        # Append WebAPI word (as bytes)
        combined = pwd_md5 + WEBAPI_WORD.encode("ascii")
        out = hashlib.md5(combined).hexdigest()

        iv_list = []
        for i in range(16):
            chunk = crypt_rand_hex[i * 32: (i + 1) * 32]
            xor_a = _hex_to_bytes(chunk)
            xor_b = _hex_to_bytes(out)
            out = hashlib.md5(xor_a + xor_b).hexdigest()
            iv_list.append(out)

        # key  = iv_list[0] + iv_list[1] (32 hex pairs = 32 bytes)
        key = _hex_to_bytes(iv_list[0] + iv_list[1])
        iv_out = _hex_to_bytes(iv_list[2])
        iv_in  = _hex_to_bytes(iv_list[3])

        self._aes_out = _AES256OFBStream(key, iv_out)
        self._aes_in  = _AES256OFBStream(key, iv_in)

    # ── public API methods ────────────────────────────────────────────────────

    def ping(self) -> bool:
        """Send a PING and return True if the server responds."""
        try:
            self._call(CMD_PING, {})
            return True
        except MT5APIError:
            return True  # PING may return retcode 1 (MT_RET_OK_NONE) — still alive
        except Exception:
            return False

    def common_get(self) -> dict:
        """
        Fetch server common config (COMMON_GET).
        Returns parsed JSON dict or empty dict.
        """
        _, json_payload = self._call(CMD_COMMON_GET, {})
        return json_payload or {}

    def user_get(self, login: int) -> dict:
        """
        Fetch user record by MT5 login.
        Returns the parsed JSON user dict.
        Raises MT5APIError if login not found.
        """
        _, json_payload = self._call(CMD_USER_GET, {P_LOGIN: int(login)})
        if not json_payload:
            raise MT5APIError(MT_RET_REPORT_NODATA, f"USER_GET returned no JSON for login {login}")
        return json_payload

    def user_account_get(self, login: int) -> dict:
        """
        Fetch live trading account snapshot for MT5 login.
        Returns dict with keys: Login, Balance, Credit, Margin, MarginFree,
        MarginLevel, MarginLeverage, Profit, Equity, etc.
        """
        _, json_payload = self._call(CMD_USER_ACCOUNT_GET, {P_LOGIN: int(login)})
        if not json_payload:
            raise MT5APIError(MT_RET_REPORT_NODATA, f"USER_ACCOUNT_GET returned no JSON for login {login}")
        return json_payload

    def user_add(
        self,
        group: str,
        name: str,
        password: str,
        investor_password: str,
        leverage: int = 100,
        rights: int = 0x1E3,
        email: str = "",
        country: str = "",
        phone: str = "",
        comment: str = "",
    ) -> int:
        """
        Create a new MT5 trading account.
        Returns the new MT5 login (integer).
        """
        user_dict = {
            "Group":          group,
            "Name":           name,
            "MainPassword":   password,
            "InvestPassword": investor_password,
            "Leverage":       leverage,
            "Rights":         rights,
            "Email":          email,
            "Country":        country,
            "Phone":          phone,
            "Comment":        comment,
            "Balance":        0,
            "Login":          0,
        }
        params = {
            P_LOGIN:        0,
            P_PASS_MAIN:    password,
            P_PASS_INVESTOR: investor_password,
            P_RIGHTS:       rights,
            P_GROUP:        group,
            P_NAME:         name,
            P_LEVERAGE:     leverage,
            "EMAIL":        email,
            "COUNTRY":      country,
            "PHONE":        phone,
            "COMMENT":      comment,
            P_BALANCE:      0,
            P_BODY_TEXT:    json.dumps(user_dict),
        }
        resp_params, json_payload = self._call(CMD_USER_ADD, params)
        # Server returns LOGIN param with the assigned login
        new_login = resp_params.get(P_LOGIN) or (json_payload or {}).get("Login")
        try:
            return int(new_login)
        except (TypeError, ValueError) as exc:
            raise MT5APIError(-1, "USER_ADD: server did not return new login") from exc

    def user_deposit_change(self, login: int, amount: float, comment: str, deal_type: int = 2) -> None:
        """
        Adjust MT5 account balance (deposit / withdrawal).

        deal_type values (from mt5_deal.php MTEnDealAction):
          2 = DEAL_BALANCE (deposit)
          3 = DEAL_CREDIT
          6 = DEAL_BONUS
        """
        self._call(CMD_USER_DEPOSIT_CHANGE, {
            P_LOGIN:   int(login),
            P_TYPE:    deal_type,
            P_BALANCE: float(amount),
            P_COMMENT: comment[:128] if comment else "",
        })

    def user_logins(self, group: str) -> list[int]:
        """
        Return list of MT5 logins for a group (e.g. 'real\\*').
        """
        _, json_payload = self._call(CMD_USER_LOGINS, {P_GROUP: group})
        if not json_payload:
            return []
        if isinstance(json_payload, list):
            return [int(x) for x in json_payload if x]
        return []

    def user_password_change(
        self, login: int, new_password: str, pass_type: str = "MAIN"
    ) -> None:
        """Change MT5 account password. pass_type: MAIN | INVESTOR | API."""
        self._call(CMD_USER_PASS_CHANGE, {
            P_LOGIN:    int(login),
            "TYPE":     pass_type,
            "PASSWORD": new_password,
        })

    def user_update(self, login: int, **fields) -> dict:
        """
        Update mutable fields on an MT5 account.
        Supported fields: name, group, leverage, email, phone, country,
                          city, state, zipcode, address, comment, rights.
        Returns updated user dict.
        """
        params = {P_LOGIN: int(login)}
        field_map = {
            "name":     "NAME",
            "group":    P_GROUP,
            "leverage": P_LEVERAGE,
            "rights":   P_RIGHTS,
            "email":    "EMAIL",
            "phone":    "PHONE",
            "country":  "COUNTRY",
            "city":     "CITY",
            "state":    "STATE",
            "zipcode":  "ZIPCODE",
            "address":  "ADDRESS",
            "comment":  "COMMENT",
        }
        user_dict = {"Login": int(login)}
        for key, val in fields.items():
            param_name = field_map.get(key.lower())
            if param_name:
                params[param_name] = val
                user_dict[param_name.title()] = val
        params[P_BODY_TEXT] = json.dumps(user_dict)
        _, json_payload = self._call(CMD_USER_UPDATE, params)
        return json_payload or {}

    # ── Groups ───────────────────────────────────────────────────────────────

    def group_total(self) -> int:
        """Get total number of groups configured on the MT5 server."""
        resp_params, _ = self._call("GROUP_TOTAL", {})
        try:
            return int(resp_params.get("TOTAL", 0))
        except (TypeError, ValueError):
            return 0

    def group_next(self, index: int) -> dict:
        """Get group config at the given index."""
        _, json_payload = self._call("GROUP_NEXT", {"INDEX": int(index)})
        return json_payload or {}

    def group_get(self, name: str) -> dict:
        """Get group config by group name."""
        _, json_payload = self._call("GROUP_GET", {P_GROUP: str(name)})
        return json_payload or {}

    # ── Symbols ──────────────────────────────────────────────────────────────

    def symbol_total(self) -> int:
        """Get total number of symbols configured on the MT5 server."""
        resp_params, _ = self._call("SYMBOL_TOTAL", {})
        try:
            return int(resp_params.get("TOTAL", 0))
        except (TypeError, ValueError):
            return 0

    def symbol_next(self, index: int) -> dict:
        """Get symbol config at the given index."""
        _, json_payload = self._call("SYMBOL_NEXT", {"INDEX": int(index)})
        return json_payload or {}

    # ── Positions ────────────────────────────────────────────────────────────

    def position_get(self, login: int, symbol: str) -> dict:
        """Get position for login and symbol."""
        _, json_payload = self._call("POSITION_GET", {P_LOGIN: int(login), "SYMBOL": str(symbol)})
        return json_payload or {}

    def position_get_total(self, login: int) -> int:
        """Get total open positions for a login."""
        resp_params, _ = self._call("POSITION_GET_TOTAL", {P_LOGIN: int(login)})
        try:
            return int(resp_params.get("TOTAL", 0))
        except (TypeError, ValueError):
            return 0

    def position_get_page(self, login: int, offset: int, total: int) -> list[dict]:
        """Get a page of open positions for a login."""
        _, json_payload = self._call("POSITION_GET_PAGE", {
            P_LOGIN: int(login),
            "OFFSET": int(offset),
            "TOTAL": int(total),
        })
        if isinstance(json_payload, list):
            return json_payload
        return []

    # ── Deals ────────────────────────────────────────────────────────────────

    def deal_get(self, ticket: int) -> dict:
        """Get deal by ticket."""
        _, json_payload = self._call("DEAL_GET", {"TICKET": int(ticket)})
        return json_payload or {}

    def deal_get_total(self, login: int, from_time: int, to_time: int) -> int:
        """Get total deals for a login in time range (UNIX timestamp)."""
        from mt5_integration.client import MT5APIError
        try:
            resp_params, _ = self._call("USER_DEAL_GET_TOTAL", {
                P_LOGIN: int(login),
                "FROM": int(from_time),
                "TO": int(to_time),
            })
            return int(resp_params.get("TOTAL", 0))
        except MT5APIError as e:
            if "retcode 8:" in str(e) or "retcode 13:" in str(e):
                return 0
            raise
        except (TypeError, ValueError):
            return 0

    def deal_get_page(self, login: int, from_time: int, to_time: int, offset: int, total: int) -> list[dict]:
        """Get a page of deals for a login in time range (UNIX timestamp)."""
        try:
            _, json_payload = self._call("DEAL_GET_PAGE", {
                P_LOGIN: int(login),
                "FROM": int(from_time),
                "TO": int(to_time),
                "OFFSET": int(offset),
                "TOTAL": int(total),
            })
            return json_payload if isinstance(json_payload, list) else []
        except MT5APIError as e:
            if "retcode 8:" in str(e) or "retcode 13:" in str(e):
                return []
            raise

    # ── History ──────────────────────────────────────────────────────────────

    def history_get(self, ticket: int) -> dict:
        """Get history order by ticket."""
        _, json_payload = self._call("HISTORY_GET", {"TICKET": int(ticket)})
        return json_payload or {}

    def history_get_total(self, login: int, from_time: int, to_time: int) -> int:
        """Get total history orders for a login in time range (UNIX timestamp)."""
        try:
            resp_params, _ = self._call("HISTORY_GET_TOTAL", {
                P_LOGIN: int(login),
                "FROM": int(from_time),
                "TO": int(to_time),
            })
            return int(resp_params.get("TOTAL", 0))
        except MT5APIError as e:
            if "retcode 8:" in str(e) or "retcode 13:" in str(e):
                return 0
            raise
        except (TypeError, ValueError):
            return 0

    def history_get_page(self, login: int, from_time: int, to_time: int, offset: int, total: int) -> list[dict]:
        """Get a page of history orders for a login in time range (UNIX timestamp)."""
        try:
            _, json_payload = self._call("HISTORY_GET_PAGE", {
                P_LOGIN: int(login),
                "FROM": int(from_time),
                "TO": int(to_time),
                "OFFSET": int(offset),
                "TOTAL": int(total),
            })
            return json_payload if isinstance(json_payload, list) else []
        except MT5APIError as e:
            if "retcode 8:" in str(e) or "retcode 13:" in str(e):
                return []
            raise

    # ── Ticks ────────────────────────────────────────────────────────────────

    def tick_last(self, symbol: str) -> list[dict]:
        """Get last tick for a symbol."""
        _, json_payload = self._call("TICK_LAST", {"SYMBOL": str(symbol)})
        if isinstance(json_payload, list):
            return json_payload
        return []
