import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { SymbolsController } from './symbols.controller';
import { SymbolsService } from './symbols.service';
import { AuditModule } from '../audit/audit.module';

@Module({
  imports: [JwtModule.register({}), AuditModule],
  controllers: [SymbolsController],
  providers: [SymbolsService],
})
export class SymbolsModule {}
