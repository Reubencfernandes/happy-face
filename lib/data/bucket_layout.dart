/// Object keys inside a Happy Drive bucket. Nothing here reveals content:
/// photo ids are secret-keyed fingerprints.
abstract final class BucketLayout {
  static const keys = 'v1/keys';
  static const originalPrefix = 'v1/o/';
  static const thumbnailPrefix = 'v1/t/';
  static String original(String photoId) =>
      '$originalPrefix${photoId.substring(0, 2)}/$photoId';

  /// Piece [index] of a file too big to send as one object. Under the
  /// original's own key, so it is counted and swept with it.
  static String part(String photoId, int index) =>
      '${original(photoId)}.$index';

  /// What a piece is sealed against: its place and how many there are, so
  /// pieces can't be reordered, swapped between files or quietly dropped.
  static String partContext(String photoId, int index, int count) =>
      '${part(photoId, index)}/$count';

  static String thumbnail(String photoId) =>
      '$thumbnailPrefix${photoId.substring(0, 2)}/$photoId';
}
