/// Object keys inside a Happy Drive bucket. Nothing here reveals content:
/// photo ids are secret-keyed fingerprints.
abstract final class BucketLayout {
  static const keys = 'v1/keys';
  static const originalPrefix = 'v1/o/';
  static const thumbnailPrefix = 'v1/t/';
  static String original(String photoId) =>
      '$originalPrefix${photoId.substring(0, 2)}/$photoId';
  static String thumbnail(String photoId) =>
      '$thumbnailPrefix${photoId.substring(0, 2)}/$photoId';
}
