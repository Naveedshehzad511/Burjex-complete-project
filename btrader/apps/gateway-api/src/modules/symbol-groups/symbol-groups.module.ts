import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { SymbolGroupsController } from './symbol-groups.controller';
import { AuditModule } from '../audit/audit.module';

@Module({
  imports: [JwtModule.register({}), AuditModule],
  controllers: [SymbolGroupsController],
})
export class SymbolGroupsModule {}
