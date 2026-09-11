import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import { ValidationPipe, Logger } from '@nestjs/common';
import { SwaggerModule, DocumentBuilder } from '@nestjs/swagger';
import helmet from 'helmet';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { AppModule } from './app.module';
import { BtErrorFilter } from './common/bt-error.filter';

async function bootstrap() {
  const app = await NestFactory.create<NestExpressApplication>(AppModule, { cors: true });
  // Live path is client → TLS Caddy → bxnet_caddy → this process. Without this,
  // req.ip is the proxy and the 300/min throttle is shared by every user.
  app.set('trust proxy', Number(process.env.TRUST_PROXY_HOPS ?? 2));
  app.use(helmet());
  // Default express limit is 100kb; tenant logo upload sends base64 JSON.
  app.useBodyParser('json', { limit: '6mb' });
  app.setGlobalPrefix('v1');
  app.useGlobalPipes(
    new ValidationPipe({ whitelist: true, transform: true, forbidNonWhitelisted: true }),
  );
  // Without this every business rejection - insufficient margin, market closed,
  // no price - surfaces as a 500 "Internal server error" instead of its reason.
  app.useGlobalFilters(new BtErrorFilter());

  const config = new DocumentBuilder()
    .setTitle('B-Trader API')
    .setDescription('Multi-tenant trading platform API (mobile, admin, CRM integration)')
    .setVersion('1.0')
    .addBearerAuth()
    .addApiKey({ type: 'apiKey', name: 'X-BT-Key', in: 'header' }, 'crm-key')
    .build();
  const doc = SwaggerModule.createDocument(app, config);
  SwaggerModule.setup('docs', app, doc);

  const port = Number(process.env.API_PORT ?? 4100);
  await app.listen(port);
  new Logger('bootstrap').log(`B-Trader gateway-api on :${port} (docs at /docs)`);
}
bootstrap();
