import 'dart:math';

/// Names for a brand-new bucket. Bucket names are unique within a Hugging
/// Face account, so a fixed one like "happy-drive" collides the moment
/// someone wants a second library. A pair of words plus a number is easy to
/// read out loud and easy to tell apart in a list.
const _adjectives = [
  'amber',
  'bright',
  'breezy',
  'cheery',
  'copper',
  'cosy',
  'dandy',
  'gentle',
  'golden',
  'happy',
  'honey',
  'jolly',
  'lucky',
  'mellow',
  'merry',
  'nimble',
  'peppy',
  'plucky',
  'quiet',
  'rosy',
  'sandy',
  'snug',
  'spry',
  'sunny',
  'swift',
  'tidy',
  'velvet',
  'warm',
  'wild',
  'zesty',
];

const _nouns = [
  'acorn',
  'badger',
  'cabin',
  'canyon',
  'cove',
  'cricket',
  'delta',
  'dune',
  'ember',
  'fern',
  'finch',
  'grove',
  'harbour',
  'heron',
  'juniper',
  'kestrel',
  'lantern',
  'lark',
  'marmot',
  'meadow',
  'orchard',
  'oriole',
  'otter',
  'pebble',
  'pelican',
  'puffin',
  'quail',
  'robin',
  'sparrow',
  'tulip',
  'vixen',
  'willow',
  'yarrow',
];

/// A fresh bucket name such as `sunny-otter-482`.
///
/// Always valid for Hugging Face: lower-case letters, digits and dashes,
/// starting with a letter.
String generateBucketName([Random? random]) {
  final r = random ?? Random.secure();
  final adjective = _adjectives[r.nextInt(_adjectives.length)];
  final noun = _nouns[r.nextInt(_nouns.length)];
  return '$adjective-$noun-${100 + r.nextInt(900)}';
}
