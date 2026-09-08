import { Body, Controller, Delete, Get, Param, Patch, Post, UseGuards } from '@nestjs/common';
import { ApiTags, ApiBearerAuth, ApiOperation } from '@nestjs/swagger';
import { HqGuard } from '../../common/hq.guard';
import { JwtAuthGuard } from '../../common/jwt.guard';
import { Roles } from '../../common/decorators';
import { HqService } from './hq.service';
import { HqRegistryService } from './hq-registry.service';

/**
 * Read-only endpoint each company deployment exposes to the central HQ
 * dashboard. Auth: X-HQ-Token (see HqGuard). There are deliberately no write
 * routes behind this token.
 */
@ApiTags('hq')
@Controller('hq')
export class HqController {
  constructor(private readonly svc: HqService) {}

  @Get('overview')
  @UseGuards(HqGuard)
  @ApiOperation({ summary: 'Read-only per-tenant stats for the central HQ dashboard' })
  overview() {
    return this.svc.overview();
  }
}

/**
 * Central-side registry management + fan-out (SUPER_ADMIN only). Lives in the
 * same module so any deployment CAN act as the HQ, but only the one where the
 * super admin registers servers actually does.
 */
@ApiTags('hq')
@ApiBearerAuth()
@UseGuards(JwtAuthGuard)
@Roles('SUPER_ADMIN')
@Controller('hq/servers')
export class HqRegistryController {
  constructor(private readonly svc: HqRegistryService) {}

  @Get() @ApiOperation({ summary: 'List registered company servers (tokens never returned)' })
  list() { return this.svc.list(); }

  @Post() @ApiOperation({ summary: 'Register a company server (name, baseUrl, token)' })
  create(@Body() body: any) { return this.svc.create(body); }

  @Patch(':id') @ApiOperation({ summary: 'Update a company server (empty token = keep existing)' })
  update(@Param('id') id: string, @Body() body: any) { return this.svc.update(id, body); }

  @Delete(':id') @ApiOperation({ summary: 'Remove a company server from the registry' })
  remove(@Param('id') id: string) { return this.svc.remove(id); }

  @Get('companies') @ApiOperation({ summary: 'Poll every registered server and aggregate overviews' })
  companies() { return this.svc.companies(); }
}
