import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { AuditModule } from '../audit/audit.module';
import { ServerHeartbeatController, ServersController } from './servers.controller';
import { ServersService } from './servers.service';

@Module({
  imports: [JwtModule.register({}), AuditModule],
  controllers: [ServersController, ServerHeartbeatController],
  providers: [ServersService],
})
export class ServersModule {}
