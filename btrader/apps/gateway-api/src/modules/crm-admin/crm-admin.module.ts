import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { CrmAdminController } from './crm-admin.controller';
import { AuditModule } from '../audit/audit.module';

/** Admin-facing CRM integration settings (webhook + inbound API keys), per tenant. */
@Module({
  imports: [JwtModule.register({}), AuditModule],
  controllers: [CrmAdminController],
})
export class CrmAdminModule {}
