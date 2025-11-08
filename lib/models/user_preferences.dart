// lib/models/user_preferences.dart
import 'dart:convert';
// ignore: unused_import
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UserPreferences {
  // core fields
  String? id; // uuid from auth
  String? fullName;
  String? username;
  String? avatarUrl;
  String? schoolId;
  String? schoolName;
  double? budget;
  List<String> favoritedOptions = [];
  Map<String, dynamic> preferences = {};

  // additional profile fields requested by screens
  String? subscriptionTier; // e.g. "Membership", "Tickets", "Gist Us"
  String? phoneNumber;
  double? weight;
  double? height;
  int? age;
  String? bloodGroup;

  UserPreferences();

  /// Load from local storage (fast) and then try to load server profile (if signed in)
  Future<void> loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();

    // Your existing full local load (keep this unchanged)
    id = prefs.getString('prefs_id');
    fullName = prefs.getString('prefs_fullName');
    username = prefs.getString('prefs_username');
    avatarUrl = prefs.getString('prefs_avatarUrl');
    schoolId = prefs.getString('prefs_schoolId');
    schoolName = prefs.getString('prefs_schoolName');
    budget = prefs.containsKey('prefs_budget')
        ? prefs.getDouble('prefs_budget')
        : null;
    favoritedOptions = prefs.getStringList('prefs_favoritedOptions') ?? [];
    final prefJson = prefs.getString('prefs_preferences');
    if (prefJson != null) {
      try {
        preferences = Map<String, dynamic>.from(jsonDecode(prefJson) as Map);
      } catch (_) {
        preferences = {};
      }
    }
    // extra fields
    subscriptionTier = prefs.getString('prefs_subscriptionTier');
    phoneNumber = prefs.getString('prefs_phoneNumber');
    weight = prefs.containsKey('prefs_weight')
        ? prefs.getDouble('prefs_weight')
        : null;
    height = prefs.containsKey('prefs_height')
        ? prefs.getDouble('prefs_height')
        : null;
    age = prefs.containsKey('prefs_age') ? prefs.getInt('prefs_age') : null;
    bloodGroup = prefs.getString('prefs_bloodGroup');

    // If the user is signed in, attempt to merge/load server profile (but be careful not to wipe good local data)
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user != null) {
      await _loadOrCreateProfile(user.id);
    }

    // Add this call to persist any merged changes locally
    await savePreferences();
  }

  /// Save to SharedPreferences and also to Supabase profiles (if signed in).
  Future<void> savePreferences() async {
    final prefs = await SharedPreferences.getInstance();

    // Local writes: always write the favorites (even if empty) so local+server can stay consistent
    if (id != null) await prefs.setString('prefs_id', id!);
    if (fullName != null) await prefs.setString('prefs_fullName', fullName!);
    if (username != null) await prefs.setString('prefs_username', username!);
    if (avatarUrl != null) await prefs.setString('prefs_avatarUrl', avatarUrl!);
    if (schoolId != null) await prefs.setString('prefs_schoolId', schoolId!);
    if (schoolName != null)
      await prefs.setString('prefs_schoolName', schoolName!);
    if (budget != null) await prefs.setDouble('prefs_budget', budget!);

    // Always persist favorited options locally (even empty list)
    await prefs.setStringList('prefs_favoritedOptions', favoritedOptions);
    await prefs.setString('prefs_preferences', jsonEncode(preferences));

    // extra fields
    if (subscriptionTier != null) {
      await prefs.setString('prefs_subscriptionTier', subscriptionTier!);
    }
    if (phoneNumber != null) {
      await prefs.setString('prefs_phoneNumber', phoneNumber!);
    }
    if (weight != null) {
      await prefs.setDouble('prefs_weight', weight!);
    }
    if (height != null) {
      await prefs.setDouble('prefs_height', height!);
    }
    if (age != null) {
      await prefs.setInt('prefs_age', age!);
    }
    if (bloodGroup != null) {
      await prefs.setString('prefs_bloodGroup', bloodGroup!);
    }

    // push to Supabase if logged in
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user != null) {
      try {
        // Ensure there is a profile row for this user (only creates if missing)
        await _ensureProfileExists(user.id);

        // Build an "updates" map with current values.
        // We intentionally include favorited_options (always) to keep server in sync.
        final Map<String, dynamic> updates = {};

        if (fullName != null && fullName!.trim().isNotEmpty) {
          updates['full_name'] = fullName!.trim();
        }
        if (username != null && username!.trim().isNotEmpty) {
          updates['username'] = username!.trim();
        }
        if (avatarUrl != null && avatarUrl!.trim().isNotEmpty) {
          updates['avatar_url'] = avatarUrl!.trim();
        }
        if (schoolId != null && schoolId!.trim().isNotEmpty) {
          updates['school_id'] = schoolId!.trim();
        }
        if (schoolName != null && schoolName!.trim().isNotEmpty) {
          updates['school_name'] = schoolName!.trim();
        }
        if (budget != null) {
          updates['budget'] = budget;
        }

        // ALWAYS include favorited_options (convert to a plain list)
        updates['favorited_options'] = favoritedOptions;
        updates['preferences'] = preferences;

        // extra fields (only include if present)
        if (subscriptionTier != null)
          updates['subscription_tier'] = subscriptionTier;
        if (phoneNumber != null) updates['phone_number'] = phoneNumber;
        if (weight != null) updates['weight'] = weight;
        if (height != null) updates['height'] = height;
        if (age != null) updates['age'] = age;
        if (bloodGroup != null) updates['blood_group'] = bloodGroup;

        updates['updated_at'] = DateTime.now().toUtc().toIso8601String();

        // If there are updates, persist them (update the user's row)
        if (updates.isNotEmpty) {
          await supabase.from('profiles').update(updates).eq('id', user.id);
        }
      } catch (e) {
        // don't crash the app if DB update fails; keep local prefs
        // optionally log this to your monitoring or webhook
      }
    }
  }

  /// Ensure a profile row exists in `public.profiles`. If missing, insert a minimal row.
  Future<void> _ensureProfileExists(String userId) async {
    final supabase = Supabase.instance.client;
    try {
      final existing = await supabase
          .from('profiles')
          .select('id')
          .eq('id', userId)
          .maybeSingle();
      if (existing == null) {
        final insert = {
          'id': userId,
          'email': Supabase.instance.client.auth.currentUser?.email,
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'favorited_options': <String>[], // explicit empty default
        };
        await supabase.from('profiles').insert(insert);
      }
    } catch (_) {
      // DB unreachable: nothing to do here
    }
  }

  /// Ensure there's a profile row in Supabase and load it into this object.
  /// IMPORTANT: Do not overwrite local favorites with null/empty server values.
  Future<void> _loadOrCreateProfile(String userId) async {
    final supabase = Supabase.instance.client;
    try {
      final resp = await supabase
          .from('profiles')
          .select()
          .eq('id', userId)
          .maybeSingle();

      if (resp != null) {
        // load core fields (defensive)
        id = resp['id']?.toString() ?? userId;
        fullName = resp['full_name'] as String?;
        username = resp['username'] as String?;
        avatarUrl = resp['avatar_url'] as String?;
        schoolId = resp['school_id'] as String?;
        schoolName = resp['school_name'] as String?;

        // favorited_options may arrive as List, String (json), or Map - parse defensively
        final fav = resp['favorited_options'];
        List<String> parsedFavs = [];
        if (fav != null) {
          if (fav is List) {
            parsedFavs = fav.map((e) => e.toString()).toList();
          } else if (fav is String) {
            try {
              final dynamic parsed = jsonDecode(fav);
              if (parsed is List)
                parsedFavs = parsed.map((e) => e.toString()).toList();
            } catch (_) {
              // ignore parse error
            }
          } else if (fav is Map) {
            try {
              parsedFavs =
                  (fav as Map).values.map((e) => e.toString()).toList();
            } catch (_) {
              parsedFavs = [];
            }
          }
        }

        // Only overwrite local favoritedOptions if server provided a **non-empty** list.
        // This protects local favorites from being wiped by null/empty server values.
        if (parsedFavs.isNotEmpty) {
          favoritedOptions = parsedFavs;
        }
        // If parsedFavs is empty, keep the existing local favoritedOptions as-is.

        // preferences JSONB
        final prefsJson = resp['preferences'];
        if (prefsJson != null) {
          try {
            preferences = Map<String, dynamic>.from(prefsJson as Map);
          } catch (_) {
            preferences = {};
          }
        }

        // extra fields
        subscriptionTier = resp['subscription_tier'] as String?;
        phoneNumber = resp['phone_number'] as String?;

        // numeric conversions (defensive)
        final w = resp['weight'];
        if (w is num) {
          weight = w.toDouble();
        } else if (w is String) {
          weight = double.tryParse(w);
        }

        final h = resp['height'];
        if (h is num) {
          height = h.toDouble();
        } else if (h is String) {
          height = double.tryParse(h);
        }

        final a = resp['age'];
        if (a is int) {
          age = a;
        } else if (a is String) {
          age = int.tryParse(a);
        }

        bloodGroup = resp['blood_group'] as String?;

        // persist locally (this will not overwrite favorites unless server had a non-empty list)
        await savePreferences();
        return;
      }

      // If no profile exists, create a minimal one
      final insert = {
        'id': userId,
        'full_name': null,
        'username': null,
        'avatar_url': null,
        'school_id': null,
        'school_name': null,
        'favorited_options': <String>[],
        'preferences': <String, dynamic>{},
        'subscription_tier': null,
        'phone_number': null,
        'weight': null,
        'height': null,
        'age': null,
        'blood_group': null,
      };

      await supabase.from('profiles').insert(insert);

      // keep local defaults (empty)
      id = userId;
      favoritedOptions =
          favoritedOptions; // keep whatever local list exists (likely empty)
      preferences = {};
      subscriptionTier = null;
      phoneNumber = null;
      weight = null;
      height = null;
      age = null;
      bloodGroup = null;

      await savePreferences();
      return;
    } catch (e) {
      // DB unreachable — keep empty defaults but keep local favorites intact
      id = userId;
      preferences = preferences ?? {};
      subscriptionTier = subscriptionTier;
      phoneNumber = phoneNumber;
      weight = weight;
      height = height;
      age = age;
      bloodGroup = bloodGroup;
      // ensure local saved
      await savePreferences();
      return;
    }
  }

  /// Clear local cache (useful on sign out)
  /// NOTE: we intentionally keep prefs_favoritedOptions here to avoid deleting favorites on sign-out.
  Future<void> clearLocal() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.remove('prefs_id');
    await prefs.remove('prefs_fullName');
    await prefs.remove('prefs_username');
    await prefs.remove('prefs_avatarUrl');
    await prefs.remove('prefs_schoolId');
    await prefs.remove('prefs_schoolName');
    await prefs.remove('prefs_budget');
    // Do NOT remove 'prefs_favoritedOptions' so favorites persist locally across sessions.
    await prefs.remove('prefs_preferences');

    await prefs.remove('prefs_subscriptionTier');
    await prefs.remove('prefs_phoneNumber');
    await prefs.remove('prefs_weight');
    await prefs.remove('prefs_height');
    await prefs.remove('prefs_age');
    await prefs.remove('prefs_bloodGroup');

    id = null;
    fullName = null;
    username = null;
    avatarUrl = null;
    schoolId = null;
    schoolName = null;
    budget = null;
    // keep favoritedOptions in memory? we'll clear it to represent logged-out user
    // but because we preserved local storage, it will be reloaded for the next session
    favoritedOptions = [];
    preferences = {};
    subscriptionTier = null;
    phoneNumber = null;
    weight = null;
    height = null;
    age = null;
    bloodGroup = null;
  }
}
