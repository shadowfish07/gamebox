import test from 'node:test';
import assert from 'node:assert/strict';
import { CATS, RARITIES, createState, drawCat, newTicket, claimTicket, openRegion, toggleFavorite, restoreState, ScratchCoverage } from './collection.mjs';

test('catalog has 24 distinct cats and the agreed rarity pools', () => {
  assert.equal(new Set(CATS.map(cat => cat.id)).size, 24);
  assert.deepEqual(RARITIES.map(r => CATS.filter(c => c.rarity === r.id).length), [12, 7, 4, 1]);
  assert.equal(RARITIES.reduce((sum, r) => sum + r.weight, 0), 10000);
});

test('draw boundaries select the correct pool, and each member is reachable', () => {
  for (const [roll, rarity] of [[0, 0], [.699999, 0], [.7, 1], [.939999, 1], [.94, 2], [.994999, 2], [.995, 3], [.999999, 3]]) {
    let i = 0;
    assert.equal(drawCat(() => [roll, .999999][i++]).rarity, rarity);
  }
  for (const [r, roll] of [0, .7, .94, .995].entries()) {
    const pool = CATS.filter(c => c.rarity === r);
    pool.forEach((cat, index) => {
      let i = 0;
      assert.equal(drawCat(() => [roll, index / pool.length][i++]).id, cat.id);
    });
  }
});

test('unrevealed tickets cannot be claimed or rerolled; mode switching keeps reward', () => {
  const state = createState();
  newTicket(state, 'photo', () => 0);
  const id = state.ticket.catId;
  assert.equal(claimTicket(state), null);
  newTicket(state, 'paws', () => .999999);
  assert.equal(state.ticket.catId, id);
  assert.equal(state.total, 0);
  assert.equal(state.ticket.mode, 'paws');
  for (let i = 0; i < 4; i++) openRegion(state, String(i));
  assert.equal(claimTicket(state).isNew, true);
  assert.equal(claimTicket(state), null);
  assert.equal(state.total, 1);
  assert.equal(state.collection[id].count, 1);
});

test('career clue must open before portrait, and duplicates do not inflate completion', () => {
  const state = createState();
  for (let i = 0; i < 2; i++) {
    newTicket(state, 'career', () => 0);
    assert.equal(openRegion(state, 'portrait'), false);
    openRegion(state, 'clue');
    assert.equal(claimTicket(state), null);
    openRegion(state, 'portrait');
    const result = claimTicket(state, '2026-09-07T00:00:00.000Z');
    assert.equal(result.isNew, i === 0);
  }
  assert.equal(state.total, 2);
  assert.equal(Object.keys(state.collection).length, 1);
  assert.equal(state.collection[CATS[0].id].count, 2);
});

test('showcase accepts only owned cats, prevents duplicates, and caps at six', () => {
  const state = createState();
  assert.equal(toggleFavorite(state, CATS[0].id), 'unowned');
  for (const cat of CATS.slice(0, 7)) state.collection[cat.id] = { count: 1, first: '2026-09-07T00:00:00.000Z' };
  for (const cat of CATS.slice(0, 6)) assert.equal(toggleFavorite(state, cat.id), 'added');
  assert.equal(toggleFavorite(state, CATS[6].id), 'full');
  assert.equal(toggleFavorite(state, CATS[0].id), 'removed');
  assert.equal(state.favorites.length, 5);
});

test('save roundtrip retains ticket, collection and showcase without re-awarding', () => {
  const state = createState();
  newTicket(state, 'photo', () => 0);
  openRegion(state, 'portrait');
  claimTicket(state);
  toggleFavorite(state, CATS[0].id);
  const restored = restoreState(JSON.stringify(state));
  assert.deepEqual(restored, state);
  assert.equal(claimTicket(restored), null);
});

test('partially scratched ticket survives reload and selecting the same mode', () => {
  const state = createState();
  newTicket(state, 'photo', () => .5);
  state.ticket.strokes.portrait = [[.1, .1, .8, .1, .07]];
  const restored = restoreState(JSON.stringify(state));
  newTicket(restored, 'photo', () => .9999);
  assert.deepEqual(restored.ticket, state.ticket);
  assert.equal(restored.total, 0);
  assert.equal(claimTicket(restored), null);
});

test('corrupt claimed tickets, out-of-order reveals and malformed strokes are rejected', () => {
  const state = createState();
  newTicket(state, 'career', () => 0);
  for (const patch of [
    { claimed: true },
    { opened: ['portrait'] },
    { opened: ['clue', 'clue'] },
    { strokes: { portrait: [[0, 0, 3, 0, .1]] } },
    { strokes: { unknown: [] } },
  ]) assert.throws(() => restoreState(JSON.stringify({ ...state, ticket: { ...state.ticket, ...patch } })));
});

test('invalid saves fail explicitly and never become trusted collection state', () => {
  for (const value of ['{', '{}', JSON.stringify({ ...createState(), collection: { unknown: { count: 2 } } }), JSON.stringify({ ...createState(), favorites: ['unknown'] })]) {
    assert.throws(() => restoreState(value));
  }
});

test('scratch coverage measures unique erased area, not repeated distance', () => {
  const coverage = new ScratchCoverage();
  for (let i = 0; i < 100; i++) coverage.erase(.1, .1, .9, .1, .065);
  assert.ok(coverage.ratio < .2);
  for (let y = 0; y <= 1; y += .08) coverage.erase(0, y, 1, y, .065);
  assert.ok(coverage.ratio > .95);
});
