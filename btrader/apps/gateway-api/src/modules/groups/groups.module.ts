import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { GroupsController } from './groups.controller';
import { AuditModule } from '../audit/audit.module';

/** Client trading-group management (markup, commission, defaults, assignment). */
@Module({
  imports: [JwtModule.register({}), AuditModule],
  controllers: [GroupsController],
})
export class GroupsModule {}
