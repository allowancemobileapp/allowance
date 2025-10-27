// lib/shared/services/storage_service.dart
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_service.dart';

class StorageService {
  StorageService._();
  static final StorageService instance = StorageService._();

  final SupabaseClient _supabase = SupabaseService.instance.client;
  final String _bucket = dotenv.env['GIST_IMAGES_BUCKET'] ?? 'gist-images';

  /// Uploads [file] and returns the public URL.
  Future<String> uploadGistImage({
    required File file,
    String? subPath,
  }) async {
    final fileName = path.basename(file.path);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final safeSubPath =
        (subPath != null && subPath.isNotEmpty) ? '$subPath/' : '';
    final storagePath = '$safeSubPath$timestamp\_$fileName';

    try {
      // Upload: this returns the uploaded path (String) and will throw on failure.
      await _supabase.storage.from(_bucket).upload(storagePath, file);

      // For public bucket:
      final publicUrl =
          _supabase.storage.from(_bucket).getPublicUrl(storagePath);

      // If you prefer signed URLs for private buckets:
      // final signed = await _supabase.storage.from(_bucket).createSignedUrl(storagePath, 60 * 60);
      // return signed;

      return publicUrl;
    } catch (e, st) {
      debugPrint('StorageService.uploadGistImage error: $e\n$st');
      rethrow;
    }
  }
}
