import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { TenantsController, UploadsController } from './tenants.controller';
import { TenantsService } from './tenants.service';
import { AuditModule } from '../audit/audit.module';

@Module({
  imports: [JwtModule.register({}), AuditModule],
  controllers: [TenantsController, UploadsController],
  providers: [TenantsService],
})
export class TenantsModule {}
