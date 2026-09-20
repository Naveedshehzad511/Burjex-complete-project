import { Body, Controller, Get, Headers, Ip, Param, Patch, Post, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { JwtAuthGuard } from '../../common/jwt.guard';
import { CurrentUser, Roles } from '../../common/decorators';
import { ServersService } from './servers.service';

@ApiTags('servers')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Roles('SUPER_ADMIN', 'TENANT_ADMIN')
@Controller('admin/servers')
export class ServersController {
  constructor(private readonly servers: ServersService) {}

  @Get()
  @ApiOperation({ summary: 'List monitored server registry and derived health' })
  list() {
    return this.servers.list();
  }

  @Get('settings')
  @ApiOperation({ summary: 'Get configurable resource and heartbeat thresholds' })
  async settings() {
    return (await this.servers.list()).settings;
  }

  @Patch('settings')
  @ApiOperation({ summary: 'Update configurable server-health thresholds' })
  updateSettings(@Body() body: any, @CurrentUser() user: any, @Ip() ip: string) {
    return this.servers.updateSettings(body, user.id, ip);
  }

  @Post()
  @ApiOperation({ summary: 'Add a registry-only monitored server; no credentials are accepted' })
  create(@Body() body: any, @CurrentUser() user: any, @Ip() ip: string) {
    return this.servers.create(body, user.id, ip);
  }

  @Get(':id')
  @ApiOperation({ summary: 'Get a server with recent heartbeat snapshots and events' })
  detail(@Param('id') id: string) {
    return this.servers.detail(id);
  }

  @Patch(':id')
  @ApiOperation({ summary: 'Update non-dangerous server registry fields' })
  update(@Param('id') id: string, @Body() body: any, @CurrentUser() user: any, @Ip() ip: string) {
    return this.servers.update(id, body, user.id, ip);
  }

  @Post(':id/actions')
  @ApiOperation({ summary: 'Confirmed server actions; live restart is SUPER_ADMIN weekend-only and safety-gated' })
  action(@Param('id') id: string, @Body() body: any, @CurrentUser() user: any, @Ip() ip: string) {
    return this.servers.action(id, body, user.id, user.role, ip);
  }
}

// Deliberately separate from admin JWT routes: only the local monitoring agent
// with SERVER_MONITOR_AGENT_TOKEN can post compact snapshots. It cannot read
// registry data or invoke any action.
@ApiTags('servers')
@Controller('monitoring')
export class ServerHeartbeatController {
  constructor(private readonly servers: ServersService) {}

  @Post('heartbeat')
  @ApiOperation({ summary: 'Receive a lightweight monitoring-agent heartbeat' })
  heartbeat(@Body() body: any, @Headers('x-server-agent-token') token?: string) {
    return this.servers.heartbeat(body, token);
  }
}
