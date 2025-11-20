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

  // ←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←
  // THIS IS THE NEW FLAG
  bool hasCompletedProfile =
      false; // true only after user finishes EditProfileScreen first time
  // ←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←

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

    // ←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←
    // LOAD THE NEW FLAG
    hasCompletedProfile = prefs.getBool('prefs_hasCompletedProfile') ?? false;
    // ←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←

    // If the user is signed in, attempt to merge/load server profile
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user != null) {
      await _loadOrCreateProfile(user.id);
    }

    // Persist any merged changes locally
    await savePreferences();
  }

  /// Save to SharedPreferences and also to Supabase profiles (if signed in)
  Future<void> savePreferences() async {
    final prefs = await SharedPreferences.getInstance();

    // ←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←
    // SAVE THE NEW FLAG
    await prefs.setBool('prefs_hasCompletedProfile', hasCompletedProfile);
    // ←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←←

    // Local writes
    if (id != null) await prefs.setString('prefs_id', id!);
    if (fullName != null) await prefs.setString('prefs_fullName', fullName!);
    if (username != null) await prefs.setString('prefs_username', username!);
    if (avatarUrl != null) await prefs.setString('prefs_avatarUrl', avatarUrl!);
    if (schoolId != null) await prefs.setString('prefs_schoolId', schoolId!);
    if (schoolName != null)
      await prefs.setString('prefs_schoolName', schoolName!);
    if (budget != null) await prefs.setDouble('prefs_budget', budget!);

    await prefs.setStringList('prefs_favoritedOptions', favoritedOptions);
    await prefs.setString('prefs_preferences', jsonEncode(preferences));

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

    // Push to Supabase if logged in
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user != null) {
      try {
        await _ensureProfileExists(user.id);

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

        updates['favorited_options'] = favoritedOptions;
        updates['preferences'] = preferences;

        if (subscriptionTier != null)
          updates['subscription_tier'] = subscriptionTier;
        if (phoneNumber != null) updates['phone_number'] = phoneNumber;
        if (weight != null) updates['weight'] = weight;
        if (height != null) updates['height'] = height;
        if (age != null) updates['age'] = age;
        if (bloodGroup != null) updates['blood_group'] = bloodGroup;

        updates['updated_at'] = DateTime.now().toUtc().toIso8601String();

        if (updates.isNotEmpty) {
          await supabase.from('profiles').update(updates).eq('id', user.id);
        }
      } catch (e) {
        // Silent fail — local data is already saved
      }
    }
  }

  /// Ensure a profile row exists in `public.profiles`
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
          'favorited_options': <String>[],
        };
        await supabase.from('profiles').insert(insert);
      }
    } catch (_) {}
  }

  /// Load or create profile from Supabase
  Future<void> _loadOrCreateProfile(String userId) async {
    final supabase = Supabase.instance.client;
    try {
      final resp = await supabase
          .from('profiles')
          .select()
          .eq('id', userId)
          .maybeSingle();

      if (resp != null) {
        id = resp['id']?.toString() ?? userId;
        fullName = resp['full_name'] as String?;
        username = resp['username'] as String?;
        avatarUrl = resp['avatar_url'] as String?;
        schoolId = resp['school_id'] as String?;
        schoolName = resp['school_name'] as String?;

        // Parse favorited_options safely
        final fav = resp['favorited_options'];
        List<String> parsedFavs = [];
        if (fav is List) {
          parsedFavs = fav.map((e) => e.toString()).toList();
        }
        if (parsedFavs.isNotEmpty) {
          favoritedOptions = parsedFavs;
        }

        // preferences
        final prefsJson = resp['preferences'];
        if (prefsJson != null) {
          try {
            preferences = Map<String, dynamic>.from(prefsJson as Map);
          } catch (_) {}
        }

        subscriptionTier = resp['subscription_tier'] as String?;
        phoneNumber = resp['phone_number'] as String?;

        final w = resp['weight'];
        weight =
            w is num ? w.toDouble() : (w is String ? double.tryParse(w) : null);

        final h = resp['height'];
        height =
            h is num ? h.toDouble() : (h is String ? double.tryParse(h) : null);

        final a = resp['age'];
        age = a is int ? a : (a is String ? int.tryParse(a) : null);

        bloodGroup = resp['blood_group'] as String?;

        await savePreferences();
        return;
      }

      // Create minimal profile if none exists
      await supabase.from('profiles').insert({
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
      });

      id = userId;
      await savePreferences();
    } catch (e) {
      id = userId;
      await savePreferences();
    }
  }

  /// Clear local cache on logout
  Future<void> clearLocal() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.remove('prefs_id');
    await prefs.remove('prefs_fullName');
    await prefs.remove('prefs_username');
    await prefs.remove('prefs_avatarUrl');
    await prefs.remove('prefs_schoolId');
    await prefs.remove('prefs_schoolName');
    await prefs.remove('prefs_budget');
    await prefs.remove('prefs_preferences');

    await prefs.remove('prefs_subscriptionTier');
    await prefs.remove('prefs_phoneNumber');
    await prefs.remove('prefs_weight');
    await prefs.remove('prefs_height');
    await prefs.remove('prefs_age');
    await prefs.remove('prefs_bloodGroup');
    await prefs.remove('prefs_hasCompletedProfile'); // ← CLEAR FLAG ON LOGOUT

    id = null;
    fullName = null;
    username = null;
    avatarUrl = null;
    schoolId = null;
    schoolName = null;
    budget = null;
    favoritedOptions = [];
    preferences = {};
    subscriptionTier = null;
    phoneNumber = null;
    weight = null;
    height = null;
    age = null;
    bloodGroup = null;
    hasCompletedProfile = false; // ← RESET IN MEMORY
  }
}
