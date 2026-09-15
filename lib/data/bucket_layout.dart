/// Object keys inside a Happy Drive bucket. Nothing here reveals content:
/// photo ids are secret-keyed fingerprints.
abstract final class BucketLayout {
  static const keys = 'v1/keys';
  static String original(String photoId) =>
      'v1/o/${photoId.substring(0, 2)}/$photoId';
  static String thumbnail(String photoId) =>
      'v1/t/${photoId.substring(0, 2)}/$photoId';
}
