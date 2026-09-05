// Public-key-only verification. This process never accesses a Keychain or private key.
import { createPublicKey, verify } from 'node:crypto';
let input = '';
for await (const chunk of process.stdin) input += chunk;
const { publicKey, signature, content } = JSON.parse(input);
const key = createPublicKey({
  key: Buffer.concat([
    Buffer.from('302a300506032b6570032100', 'hex'),
    Buffer.from(publicKey, 'base64'),
  ]),
  format: 'der',
  type: 'spki',
});
process.exit(verify(null, Buffer.from(content, 'base64'), key, Buffer.from(signature, 'base64')) ? 0 : 1);
