import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { after, before, beforeEach, test } from 'node:test';
import { assertFails, assertSucceeds, initializeTestEnvironment } from '@firebase/rules-unit-testing';
import {
  Bytes, collection, collectionGroup, deleteDoc, doc, getDoc, getDocs,
  serverTimestamp, setDoc, Timestamp, updateDoc, writeBatch,
} from 'firebase/firestore';

// Refuse to run against any remote endpoint, even when invoked outside npm test.
assert.match(process.env.FIRESTORE_EMULATOR_HOST ?? '', /^(127\.0\.0\.1|localhost):8188$/);
const projectId = 'demo-ledgerly-rules';
let environment;
const recent = () => Math.floor(Date.now() / 1000) - 30;
const authenticated = (uid, authTime = recent()) =>
  environment.authenticatedContext(uid, { auth_time: authTime }).firestore();
const path = (group, id = 'existing', uid = 'alice') => `users/${uid}/${group}/${id}`;
const marker = (db, uid = 'alice') => doc(db, `users/${uid}`);
const seed = async (entries) => environment.withSecurityRulesDisabled(async (context) => {
  const db = context.firestore();
  const batch = writeBatch(db);
  for (const [key, value] of entries) batch.set(doc(db, key), value);
  await batch.commit();
});

before(async () => {
  environment = await initializeTestEnvironment({
    projectId,
    firestore: {
      host: '127.0.0.1', port: 8188,
      rules: await readFile(new URL('../../firestore.rules', import.meta.url), 'utf8'),
    },
  });
});
beforeEach(async () => environment.clearFirestore());
after(async () => environment?.cleanup());

for (const group of ['transactions', 'budgets']) {
  test(`${group}: owner can create, read, list, update and delete`, async () => {
    const db = authenticated('alice');
    const ref = doc(db, path(group));
    await assertSucceeds(setDoc(ref, { amount: 430, category: 'Transport' }));
    assert.equal((await assertSucceeds(getDoc(ref))).data().amount, 430);
    assert.equal((await assertSucceeds(getDocs(collection(db, `users/alice/${group}`)))).size, 1);
    await assertSucceeds(updateDoc(ref, { amount: 500 }));
    await assertSucceeds(deleteDoc(ref));
    assert.equal((await assertSucceeds(getDoc(ref))).exists(), false);
  });

  test(`${group}: another account cannot read, list, create, update or delete`, async () => {
    await seed([[path(group), { amount: 430 }]]);
    const db = authenticated('bob');
    await assertFails(getDoc(doc(db, path(group))));
    await assertFails(getDocs(collection(db, `users/alice/${group}`)));
    await assertFails(setDoc(doc(db, path(group, 'forged')), { userId: 'bob', amount: 1 }));
    await assertFails(updateDoc(doc(db, path(group)), { amount: 1 }));
    await assertFails(deleteDoc(doc(db, path(group))));
  });

  test(`${group}: signed-out clients cannot access financial records`, async () => {
    await seed([[path(group), { amount: 430 }]]);
    const db = environment.unauthenticatedContext().firestore();
    await assertFails(getDoc(doc(db, path(group))));
    await assertFails(getDocs(collection(db, `users/alice/${group}`)));
    await assertFails(setDoc(doc(db, path(group, 'new')), { amount: 1 }));
    await assertFails(updateDoc(doc(db, path(group)), { amount: 1 }));
    await assertFails(deleteDoc(doc(db, path(group))));
  });

  test(`${group}: deletion marker blocks delayed writes while owner cleanup stays possible`, async () => {
    await seed([[path(group), { amount: 430 }]]);
    const db = authenticated('alice');
    await assertSucceeds(setDoc(marker(db), { deletionRequestedAt: serverTimestamp() }));
    await assertFails(setDoc(doc(db, path(group, 'delayed')), { amount: 5 }));
    await assertFails(updateDoc(doc(db, path(group)), { amount: 5 }));
    await assertSucceeds(getDoc(doc(db, path(group))));
    await assertSucceeds(getDocs(collection(db, `users/alice/${group}`)));
    await assertSucceeds(deleteDoc(doc(db, path(group))));
    await assertFails(setDoc(doc(db, path(group)), { amount: 430 }));
    const bob = authenticated('bob');
    await assertSucceeds(setDoc(doc(bob, path(group, 'own', 'bob')), { amount: 10 }));
  });

  for (const operation of ['create', 'update']) {
    test(`${group}: marker plus financial ${operation} in one batch is rejected atomically`, async () => {
      if (operation === 'update') await seed([[path(group), { amount: 430 }]]);
      const db = authenticated('alice');
      const batch = writeBatch(db);
      batch.set(marker(db), { deletionRequestedAt: serverTimestamp() });
      if (operation === 'update') batch.update(doc(db, path(group)), { amount: 5 });
      else batch.set(doc(db, path(group)), { amount: 5 });
      await assertFails(batch.commit());
      assert.equal((await getDoc(marker(db))).exists(), false);
      const saved = await getDoc(doc(db, path(group)));
      assert.equal(saved.exists(), operation === 'update');
      if (saved.exists()) assert.equal(saved.data().amount, 430);
    });
  }
}

test('deletion requires a recent owner authentication and a server timestamp', async () => {
  const stale = authenticated('alice', Math.floor(Date.now() / 1000) - 600);
  await assertFails(setDoc(marker(stale), { deletionRequestedAt: serverTimestamp() }));
  const db = authenticated('alice');
  for (const invalid of [{}, { deletionRequestedAt: null }, { deletionRequestedAt: 'now' },
    { deletionRequestedAt: Timestamp.fromMillis(1) },
    { deletionRequestedAt: serverTimestamp(), extra: true }]) {
    await assertFails(setDoc(marker(db), invalid));
  }
  await assertSucceeds(setDoc(marker(db), { deletionRequestedAt: serverTimestamp() }));
});

test('deletion marker cannot be removed, overwritten or have its protection field deleted', async () => {
  const db = authenticated('alice');
  await setDoc(marker(db), { deletionRequestedAt: serverTimestamp() });
  await assertFails(deleteDoc(marker(db)));
  await assertFails(setDoc(marker(db), {}));
  await assertFails(setDoc(marker(db), { deletionRequestedAt: serverTimestamp() }));
  await assertFails(updateDoc(marker(db), { extra: true }));
  assert.equal((await getDoc(marker(db))).exists(), true);
});

test('account root can only be read by its owner; user listing stays denied', async () => {
  await seed([['users/alice', { deletionRequestedAt: Timestamp.fromMillis(1) }]]);
  const alice = authenticated('alice');
  await assertSucceeds(getDoc(marker(alice)));
  await assertFails(getDocs(collection(alice, 'users')));
  for (const db of [authenticated('bob'), environment.unauthenticatedContext().firestore()]) {
    await assertFails(getDoc(marker(db)));
    await assertFails(setDoc(marker(db), { deletionRequestedAt: serverTimestamp() }));
    await assertFails(deleteDoc(marker(db)));
  }
});

test('unknown paths and cross-account collection group queries stay denied', async () => {
  await seed([[path('transactions'), { amount: 430 }], [path('transactions', 'other', 'bob'), { amount: 20 }]]);
  const db = authenticated('alice');
  await assertFails(getDocs(collectionGroup(db, 'transactions')));
  for (const key of ['public/example', 'users/alice/private/example', 'users/alice/transactions/existing/nested/example']) {
    await assertFails(setDoc(doc(db, key), { amount: 1 }));
    await assertFails(getDoc(doc(db, key)));
  }
});

test('all budget-backed record types retain owner isolation and deletion protection', async () => {
  const db = authenticated('alice');
  const bob = authenticated('bob');
  for (const id of ['2026-10', 'category-food', 'event-trip', 'friend-example', 'split-example']) {
    await assertSucceeds(setDoc(doc(db, path('budgets', id)), { id, amount: 100 }));
    await assertFails(getDoc(doc(bob, path('budgets', id))));
  }
  await setDoc(marker(db), { deletionRequestedAt: serverTimestamp() });
  for (const id of ['2026-10', 'category-food', 'event-trip', 'friend-example', 'split-example']) {
    await assertFails(setDoc(doc(db, path('budgets', id)), { id, amount: 200 }));
    await assertSucceeds(deleteDoc(doc(db, path('budgets', id))));
  }
});

test('a cross-account batch is rejected without partially updating the owner ledger', async () => {
  const db = authenticated('alice');
  const batch = writeBatch(db);
  batch.set(doc(db, path('transactions', 'mine')), { amount: 430 });
  batch.set(doc(db, path('transactions', 'theirs', 'bob')), { amount: 5 });
  await assertFails(batch.commit());
  assert.equal((await getDoc(doc(db, path('transactions', 'mine')))).exists(), false);
});

test('a protection field present with a malformed legacy value still blocks uploads', async () => {
  await seed([['users/alice', { deletionRequestedAt: null }]]);
  const db = authenticated('alice');
  for (const group of ['transactions', 'budgets']) {
    await assertFails(setDoc(doc(db, path(group)), { amount: 430 }));
  }
});

test('ordinary same-account transaction and budget batches remain allowed', async () => {
  const db = authenticated('alice');
  const batch = writeBatch(db);
  batch.set(doc(db, path('transactions')), { amount: 430 });
  batch.set(doc(db, path('budgets')), { amount: 35000 });
  await assertSucceeds(batch.commit());
  assert.equal((await getDoc(doc(db, path('transactions')))).data().amount, 430);
  assert.equal((await getDoc(doc(db, path('budgets')))).data().amount, 35000);
});

test('starting deletion and removing existing records in one batch stays allowed', async () => {
  await seed([['users/alice/transactions/existing', { amount: 430 }],
    ['users/alice/budgets/existing', { amount: 35000 }]]);
  const db = authenticated('alice');
  const batch = writeBatch(db);
  batch.set(marker(db), { deletionRequestedAt: serverTimestamp() });
  batch.delete(doc(db, path('transactions')));
  batch.delete(doc(db, path('budgets')));
  await assertSucceeds(batch.commit());
  assert.equal((await getDoc(marker(db))).exists(), true);
  assert.equal((await getDoc(doc(db, path('transactions')))).exists(), false);
});


test('library metadata and binary pages use the same owner and deletion boundary', async () => {
  const alice = authenticated('alice');
  const manifest = doc(alice, path('budgets', 'library-receipt-00000000-0000-0000-0000-000000000001'));
  const part = doc(alice, path('budgets', 'librarypart-test-0'));
  const batch = writeBatch(alice);
  batch.set(manifest, { libraryKind: 'receipt', revision: 'test', parts: 1 });
  batch.set(part, { payload: Bytes.fromUint8Array(new Uint8Array([1, 2, 3])) });
  await assertSucceeds(batch.commit());
  assert.deepEqual((await getDoc(part)).data().payload.toUint8Array(), new Uint8Array([1, 2, 3]));
  const bob = authenticated('bob');
  await assertFails(getDoc(doc(bob, part.path)));
  await assertFails(getDoc(doc(bob, manifest.path)));
  await setDoc(marker(alice), { deletionRequestedAt: serverTimestamp() });
  const blocked = writeBatch(alice);
  blocked.set(manifest, { revision: 'replacement' });
  blocked.set(part, { payload: Bytes.fromUint8Array(new Uint8Array([4])) });
  await assertFails(blocked.commit());
  assert.equal((await getDoc(manifest)).data().revision, 'test');
  await assertSucceeds(deleteDoc(part));
  await assertSucceeds(deleteDoc(manifest));
});

test('starting deletion cannot be combined with a library manifest or image chunk', async () => {
  const db = authenticated('alice');
  const batch = writeBatch(db);
  batch.set(marker(db), { deletionRequestedAt: serverTimestamp() });
  batch.set(doc(db, path('budgets', 'library-avatar-profile')), { parts: 1 });
  batch.set(doc(db, path('budgets', 'librarypart-test-0')), { payload: Bytes.fromUint8Array(new Uint8Array([1])) });
  await assertFails(batch.commit());
  assert.equal((await getDoc(marker(db))).exists(), false);
});

test('a bounded multi-page attachment can commit atomically with cached rule lookups', async () => {
  const db = authenticated('alice');
  const batch = writeBatch(db);
  for (let index = 0; index < 15; index++) {
    const size = index === 14 ? 216000 : 256000;
    batch.set(doc(db, path('budgets', `librarypart-bounded-${index}`)), {
      payload: Bytes.fromUint8Array(new Uint8Array(size).fill(index)),
    });
  }
  batch.set(doc(db, path('budgets', 'library-receipt-bounded')), { parts: 15, bytes: 3800000 });
  await assertSucceeds(batch.commit());
  const manifest = await getDoc(doc(db, path('budgets', 'library-receipt-bounded')));
  assert.equal(manifest.data().parts, 15);
  const replacement = writeBatch(db);
  for (let index = 0; index < 15; index++) {
    replacement.delete(doc(db, path('budgets', `librarypart-bounded-${index}`)));
    const size = index === 14 ? 216000 : 256000;
    replacement.set(doc(db, path('budgets', `librarypart-replacement-${index}`)), {
      payload: Bytes.fromUint8Array(new Uint8Array(size).fill(20 + index)),
    });
  }
  replacement.set(doc(db, path('budgets', 'library-receipt-bounded')), { parts: 15, bytes: 3800000, revision: 'replacement' });
  await assertSucceeds(replacement.commit());
  assert.equal((await getDoc(doc(db, path('budgets', 'librarypart-bounded-0')))).exists(), false);
  assert.equal((await getDoc(doc(db, path('budgets', 'library-receipt-bounded')))).data().revision, 'replacement');
});
