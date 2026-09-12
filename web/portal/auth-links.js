(function () {
  var CRM = "https://crm.burjexprime.net/api/v1";
  var params = new URLSearchParams(location.search);
  var hash = location.hash || "";
  var hashQuery = "";
  var qAt = hash.indexOf("?");
  if (qAt >= 0) hashQuery = hash.slice(qAt + 1);
  var hashParams = new URLSearchParams(hashQuery);
  var token = params.get("oauth_token") || hashParams.get("oauth_token") || "";
  var socialError = params.get("social_error") || hashParams.get("social_error") || "";
  var path = (location.pathname || "/").replace(/\/+$/, "") || "/";

  function setPref(k, v) {
    try {
      localStorage.setItem("flutter." + k, JSON.stringify(v));
    } catch (e) {}
  }

  if (token) {
    setPref("bt_access", token);
    setPref("bt_refresh", token);
    window.__bxSkipFlutter = true;
    location.replace(location.origin + "/");
    return;
  }

  function paint(html) {
    document.documentElement.style.background = "#fff";
    document.body.style.margin = "0";
    document.body.style.fontFamily = 'system-ui, -apple-system, "Segoe UI", sans-serif';
    document.body.innerHTML = html;
  }

  function shell(title, body) {
    return (
      '<div style="min-height:100vh;background:#fff;color:#002D58">' +
      '<div style="max-width:400px;margin:0 auto;padding:28px 24px 40px">' +
      '<div style="font-size:13px;letter-spacing:.08em;text-transform:uppercase;opacity:.7">Burjex Prime</div>' +
      '<h1 style="font-size:24px;margin:12px 0 20px">' + title + "</h1>" +
      body +
      "</div></div>"
    );
  }

  function field(id, label, type) {
    return (
      '<label style="display:block;font-size:13px;margin:0 0 6px">' + label + "</label>" +
      '<input id="' + id + '" type="' + type + '" style="width:100%;box-sizing:border-box;border:1px solid #C9CED8;border-radius:12px;padding:12px 14px;margin:0 0 14px;font-size:16px">'
    );
  }

  function btn(id, label) {
    return (
      '<button id="' + id + '" type="submit" style="width:100%;height:48px;border:0;border-radius:12px;background:#002D58;color:#fff;font-size:16px;font-weight:600">' +
      label +
      "</button>"
    );
  }

  function loginLink() {
    return '<p style="margin:18px 0 0;text-align:center"><a href="/login" style="color:#002D58">Back to login</a></p>';
  }

  function note(id) {
    return '<p id="' + id + '" style="min-height:1.4em;margin:0 0 12px"></p>';
  }

  if (path === "/reset-password") {
    window.__bxSkipFlutter = true;
    var uid = params.get("uid") || "";
    var resetToken = params.get("token") || "";
    paint(
      shell(
        "Reset password",
        note("bxMsg") +
          '<form id="bxForm">' +
          field("bxPass", "New password", "password") +
          field("bxConfirm", "Confirm password", "password") +
          btn("bxGo", "Update password") +
          "</form>" +
          loginLink()
      )
    );
    var msg = document.getElementById("bxMsg");
    document.getElementById("bxForm").addEventListener("submit", function (ev) {
      ev.preventDefault();
      var pass = document.getElementById("bxPass").value;
      var confirm = document.getElementById("bxConfirm").value;
      if (!uid || !resetToken) {
        msg.style.color = "#E5484D";
        msg.textContent = "This reset link is incomplete. Request a new one.";
        return;
      }
      if (pass !== confirm) {
        msg.style.color = "#E5484D";
        msg.textContent = "Passwords do not match.";
        return;
      }
      var go = document.getElementById("bxGo");
      go.disabled = true;
      msg.style.color = "#002D58";
      msg.textContent = "Saving…";
      fetch(CRM + "/auth/reset-password/", {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({
          uid: uid,
          token: resetToken,
          new_password: pass,
          confirm_password: confirm
        })
      })
        .then(function (r) {
          return r.json().then(function (j) {
            return { ok: r.ok, j: j };
          });
        })
        .then(function (res) {
          if (res.j && res.j.success) {
            msg.style.color = "#0B7A4B";
            msg.textContent = res.j.message || "Password updated. You can sign in now.";
            go.textContent = "Done";
            return;
          }
          go.disabled = false;
          msg.style.color = "#E5484D";
          msg.textContent = (res.j && res.j.message) || "This reset link is invalid or has expired.";
        })
        .catch(function () {
          go.disabled = false;
          msg.style.color = "#E5484D";
          msg.textContent = "Could not reach the server. Try again.";
        });
    });
    return;
  }

  if (path === "/verify-email") {
    window.__bxSkipFlutter = true;
    var verifyToken = params.get("token") || "";
    paint(shell("Verify email", note("bxMsg") + loginLink()));
    var vmsg = document.getElementById("bxMsg");
    if (!verifyToken) {
      vmsg.style.color = "#E5484D";
      vmsg.textContent = "This verification link is incomplete.";
      return;
    }
    vmsg.textContent = "Verifying your email…";
    fetch(CRM + "/auth/verify-email/", {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ token: verifyToken })
    })
      .then(function (r) {
        return r.json().then(function (j) {
          return { ok: r.ok, j: j };
        });
      })
      .then(function (res) {
        if (res.j && res.j.success) {
          vmsg.style.color = "#0B7A4B";
          vmsg.textContent = res.j.message || "Email verified. You can sign in now.";
          return;
        }
        vmsg.style.color = "#E5484D";
        vmsg.textContent = (res.j && res.j.message) || "This verification link is invalid or has expired.";
      })
      .catch(function () {
        vmsg.style.color = "#E5484D";
        vmsg.textContent = "Could not reach the server. Try again.";
      });
    return;
  }

  if (socialError) {
    try {
      history.replaceState({}, "", location.pathname);
    } catch (e) {}
    document.addEventListener("DOMContentLoaded", function () {
      var b = document.createElement("div");
      b.setAttribute("style", "position:fixed;left:12px;right:12px;top:12px;z-index:99999;background:#fff;color:#002D58;border:1px solid #E5484D;border-radius:12px;padding:12px 14px;font:14px/1.4 system-ui,sans-serif;box-shadow:0 8px 24px rgba(0,0,0,.12)");
      b.textContent = socialError;
      document.body.appendChild(b);
      setTimeout(function () {
        if (b.parentNode) b.parentNode.removeChild(b);
      }, 8000);
    });
  }
})();
