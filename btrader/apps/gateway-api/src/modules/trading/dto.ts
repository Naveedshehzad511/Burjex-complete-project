import {
  IsBoolean,
  IsEnum,
  IsISO8601,
  IsNumber,
  IsOptional,
  IsPositive,
  IsString,
  Min,
} from 'class-validator';

const ORDER_TYPES = [
  'MARKET', 'LIMIT', 'STOP', 'STOP_LIMIT', 'BUY_STOP', 'SELL_STOP', 'BUY_LIMIT', 'SELL_LIMIT',
] as const;

export class PlaceOrderDto {
  @IsString() accountId!: string;
  @IsString() symbol!: string;
  @IsEnum(['BUY', 'SELL']) side!: 'BUY' | 'SELL';
  @IsEnum(ORDER_TYPES) type!: (typeof ORDER_TYPES)[number];
  @IsNumber() @IsPositive() volume!: number;
  @IsOptional() @IsNumber() price?: number;
  @IsOptional() @IsNumber() stopPrice?: number;
  @IsOptional() @IsNumber() slPrice?: number;
  @IsOptional() @IsNumber() tpPrice?: number;
  @IsOptional() @IsEnum(['GTC', 'IOC', 'FOK', 'DAY', 'GTD']) timeInForce?: string;
  @IsOptional() @IsISO8601() expiresAt?: string;
  @IsOptional() @IsString() comment?: string;
  @IsOptional() @IsBoolean() oneClick?: boolean;
  @IsOptional() @IsString() clientOrderId?: string;
}

export class ModifyPositionDto {
  @IsOptional() @IsNumber() slPrice?: number | null;
  @IsOptional() @IsNumber() tpPrice?: number | null;
}

export class ModifyOrderDto {
  @IsOptional() @IsNumber() price?: number | null;
  @IsOptional() @IsNumber() stopPrice?: number | null;
  @IsOptional() @IsNumber() slPrice?: number | null;
  @IsOptional() @IsNumber() tpPrice?: number | null;
}

export class ClosePositionDto {
  @IsOptional() @IsNumber() @Min(0) volume?: number;
  @IsOptional() @IsNumber() price?: number;
}
