import { Module } from '@nestjs/common';
import { BridgeController } from './bridge.controller';

/** MT5 Manager bridge integration: symbol/group reconcile + A-book cover relay. */
@Module({
  controllers: [BridgeController],
})
export class BridgeModule {}
