import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { RiskController } from './risk.controller';
import { RiskService } from './risk.service';

@Module({
  imports: [JwtModule.register({})],
  controllers: [RiskController],
  providers: [RiskService],
})
export class RiskModule {}
