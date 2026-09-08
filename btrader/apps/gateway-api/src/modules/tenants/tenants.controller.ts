import { BadRequestException, Body, Controller, Delete, Get, NotFoundException, Param, Patch, Post, Req, Res, UseGuards } from '@nestjs/common';
import { ApiTags, ApiBearerAuth, ApiOperation } from '@nestjs/swagger';
import { JwtAuthGuard } from '../../common/jwt.guard';
import { Roles, CurrentUser } from '../../common/decorators';
import { TenantsService } from './tenants.service';
import { AuditService } from '../audit/audit.service';
import * as fs from 'fs';
import * as path from 'path';

const UPLOADS_DIR = process.env.UPLOADS_DIR ?? '/app/uploads';
const LOGO_EXT: Record<string, string> = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
};

@ApiTags('tenants')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Roles('SUPER_ADMIN')
@Controller('tenants')
export class TenantsController {
  constructor(private readonly svc: TenantsService, private readonly audit: AuditService) {}

  @Get() @ApiOperation({ summary: 'List all tenants (platform)' })
  list() { return this.svc.list(); }

  @Post() @ApiOperation({ summary: 'Create a tenant (broker brand) with branding' })
  async create(@CurrentUser() u: any, @Body() body: any) {
    const t = await this.svc.create(body);
    await this.audit.log(t.id, u.id, 'TENANT_CHANGE', 'tenant', t.id, { after: body });
    return t;
  }

  @Patch(':id/branding') @ApiOperation({ summary: 'Update white-label branding' })
  branding(@Param('id') id: string, @Body() body: any) { return this.svc.updateBranding(id, body); }

  @Post(':id/suspend') @ApiOperation({ summary: 'Suspend a tenant' })
  suspend(@Param('id') id: string, @Body() body: any) { return this.svc.suspend(id, body?.reason); }

  @Post(':id/activate') @ApiOperation({ summary: 'Re-activate a tenant' })
  activate(@Param('id') id: string) { return this.svc.activate(id); }

  @Delete(':id') @ApiOperation({ summary: 'Soft-delete a tenant' })
  remove(@Param('id') id: string) { return this.svc.remove(id); }

  @Post(':id/logo')
  @ApiOperation({ summary: 'Upload a tenant logo (base64 JSON) and set branding.logoUrl' })
  async uploadLogo(@Param('id') id: string, @Body() body: any, @Req() req: any) {
    const filename = String(body?.filename ?? '');
    const ext = path.extname(filename).toLowerCase();
    if (!LOGO_EXT[ext]) throw new BadRequestException(`file type must be one of: ${Object.keys(LOGO_EXT).join(' ')}`);
    const data = Buffer.from(String(body?.dataBase64 ?? ''), 'base64');
    if (data.length === 0) throw new BadRequestException('dataBase64 is empty');
    if (data.length > 4 * 1024 * 1024) throw new BadRequestException('logo too large (max 4 MB)');

    const dir = path.join(UPLOADS_DIR, 'logos');
    fs.mkdirSync(dir, { recursive: true });
    const name = `${id}-${Date.now()}${ext}`;
    fs.writeFileSync(path.join(dir, name), data);

    // Absolute URL so both apps can render it. Caddy preserves the original
    // Host header, so the request host IS the public api.<domain>.
    const host = req.headers['x-forwarded-host'] ?? req.headers.host;
    const logoUrl = `https://${host}/v1/uploads/logos/${name}`;
    await this.svc.updateBranding(id, { logoUrl });
    return { logoUrl };
  }
}

/** Public, unauthenticated serving of uploaded logos (referenced by branding). */
@ApiTags('tenants')
@Controller('uploads')
export class UploadsController {
  @Get('logos/:name')
  @ApiOperation({ summary: 'Serve an uploaded tenant logo' })
  serve(@Param('name') name: string, @Res() res: any) {
    // Sanitize: filenames are `<uuid>-<ts>.<ext>` — no separators allowed.
    if (!/^[A-Za-z0-9-]+\.[A-Za-z0-9]+$/.test(name)) throw new BadRequestException('bad name');
    const ext = path.extname(name).toLowerCase();
    const mime = LOGO_EXT[ext];
    if (!mime) throw new BadRequestException('bad type');
    const file = path.join(UPLOADS_DIR, 'logos', name);
    if (!fs.existsSync(file)) throw new NotFoundException();
    res.setHeader('Content-Type', mime);
    res.setHeader('Cache-Control', 'public, max-age=86400');
    // Logos render on the admin/trader origins; helmet's default CORP would block them.
    res.setHeader('Cross-Origin-Resource-Policy', 'cross-origin');
    fs.createReadStream(file).pipe(res);
  }
}
