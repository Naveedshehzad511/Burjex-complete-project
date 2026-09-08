import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { HqController, HqRegistryController } from './hq.controller';
import { HqService } from './hq.service';
import { HqRegistryService } from './hq-registry.service';

@Module({
  imports: [JwtModule.register({})],
  controllers: [HqController, HqRegistryController],
  providers: [HqService, HqRegistryService],
})
export class HqModule {}
