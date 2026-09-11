import { Body, Controller, Post, Req, UseGuards } from '@nestjs/common';
import { ApiTags, ApiOperation } from '@nestjs/swagger';
import { Throttle } from '@nestjs/throttler';
import { IsEmail, IsString, IsOptional, MinLength } from 'class-validator';
import { Transform } from 'class-transformer';
import { Request } from 'express';
import { AuthService } from './auth.service';
import { JwtAuthGuard } from '../../common/jwt.guard';
import { Roles, CurrentTenant } from '../../common/decorators';
import { clientIp } from '../../common/client-ip';
import { THROTTLE_AUTH_LIMIT, THROTTLE_AUTH_TTL_MS } from '../../common/throttle.config';

class LoginDto {
  @Transform(({ value }) => String(value ?? '').trim().toLowerCase())
  @IsEmail()
  email!: string;
  @IsString() @MinLength(6) password!: string;
}
class AccountLoginDto {
  @IsString() login!: string; // trading account number
  @IsString() @MinLength(4) password!: string;
}
class RefreshDto {
  @IsString() refreshToken!: string;
}
class DemoRegisterDto {
  @IsEmail() email!: string;
  @IsOptional() @IsString() firstName?: string;
  @IsOptional() @IsString() lastName?: string;
  @IsOptional() @IsString() phone?: string;
  @IsOptional() @IsString() @MinLength(6) password?: string;
  @IsOptional() @IsString() currency?: string;
  @IsOptional() leverage?: number;
  @IsOptional() balance?: number;
}
class ForceLogoutDto {
  @IsString() userId!: string;
}

@ApiTags('auth')
@Controller('auth')
export class AuthController {
  constructor(private readonly auth: AuthService) {}

  @Post('login')
  @Throttle({ default: { limit: THROTTLE_AUTH_LIMIT, ttl: THROTTLE_AUTH_TTL_MS } })
  @ApiOperation({ summary: 'Login (trader/admin). Tenant resolved from host/header.' })
  login(@Body() dto: LoginDto, @CurrentTenant() tenant: any, @Req() req: Request) {
    return this.auth.login(
      tenant?.id ?? null,
      dto.email,
      dto.password,
      clientIp(req),
      req.headers['user-agent'],
    );
  }

  @Post('account-login')
  @Throttle({ default: { limit: THROTTLE_AUTH_LIMIT, ttl: THROTTLE_AUTH_TTL_MS } })
  @ApiOperation({ summary: 'Login by trading account number + password (MT5-style, trader app).' })
  accountLogin(@Body() dto: AccountLoginDto, @CurrentTenant() tenant: any, @Req() req: Request) {
    return this.auth.loginByAccount(
      tenant?.id ?? null,
      dto.login,
      dto.password,
      clientIp(req),
      req.headers['user-agent'],
    );
  }

  @Post('demo-register')
  @Throttle({ default: { limit: THROTTLE_AUTH_LIMIT, ttl: THROTTLE_AUTH_TTL_MS } })
  @ApiOperation({ summary: 'Self-serve demo signup (lead-gen): create user + demo account, auto-login.' })
  demoRegister(@Body() dto: DemoRegisterDto, @CurrentTenant() tenant: any, @Req() req: Request) {
    return this.auth.registerDemo(tenant?.id ?? null, dto, clientIp(req), req.headers['user-agent']);
  }

  @Post('refresh')
  @ApiOperation({ summary: 'Issue a fresh access token from a refresh token' })
  refresh(@Body() dto: RefreshDto) {
    return this.auth.refresh(dto.refreshToken);
  }

  @Post('logout')
  @ApiOperation({ summary: 'Revoke current refresh session' })
  logout(@Body() dto: RefreshDto) {
    return this.auth.logout(dto.refreshToken);
  }

  @Post('force-logout')
  @UseGuards(JwtAuthGuard)
  @Roles('SUPER_ADMIN', 'TENANT_ADMIN')
  @ApiOperation({ summary: 'Admin: revoke all sessions for a user' })
  forceLogout(@Body() dto: ForceLogoutDto) {
    return this.auth.forceLogout(dto.userId);
  }
}
