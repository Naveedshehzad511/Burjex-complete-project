import 'reflect-metadata';
import { describe, expect, it } from 'vitest';
import { plainToInstance } from 'class-transformer';
import { validate } from 'class-validator';
import { CloseScopedDto, CLOSE_SCOPES } from './dto';

const check = async (body: unknown) => validate(plainToInstance(CloseScopedDto, body as object));

describe('Close all profitable / losing: the scope', () => {
  it('knows exactly the two narrower scopes (Close All has its own route and never narrows)', () => {
    expect([...CLOSE_SCOPES]).toEqual(['profitable', 'losing']);
  });

  it('accepts profitable and losing', async () => {
    for (const scope of CLOSE_SCOPES) expect(await check({ scope })).toHaveLength(0);
  });

  it('REQUIRES a valid scope, so a missing or mistyped one can never become a Close All', async () => {
    for (const body of [{}, { scope: 'all' }, { scope: 'everything' }, { scope: 'Profitable' }, { scope: '' }, { scope: null }, { scope: 5 }]) {
      const errors = await check(body);
      expect(errors.length, JSON.stringify(body)).toBeGreaterThan(0);
    }
  });
});
