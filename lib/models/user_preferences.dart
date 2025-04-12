import 'package:shared_preferences/shared_preferences.dart';

class UserPreferences {
  String? username;
  String? school;
  double? budget;
  Set<String> favoritedOptions = {};
  String subscriptionTier = "Free";
  String? phoneNumber;
  double? weight; // Added for ProfileScreen
  double? height; // Added for ProfileScreen
  int? age; // Added for ProfileScreen
  String? bloodGroup; // Added for ProfileScreen

  // Constructor
  UserPreferences({
    this.username,
    this.school,
    this.budget,
    this.phoneNumber,
    Set<String>? favoritedOptions,
    this.subscriptionTier = "Free",
    this.weight,
    this.height,
    this.age,
    this.bloodGroup,
  }) : favoritedOptions = favoritedOptions ?? {};

  // Load preferences from local storage
  Future<void> loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    username = prefs.getString('username');
    school = prefs.getString('school');
    budget = prefs.getDouble('budget');
    favoritedOptions = prefs.getStringList('favoritedOptions')?.toSet() ?? {};
    subscriptionTier = prefs.getString('subscriptionTier') ?? "Free";
    phoneNumber = prefs.getString('phoneNumber');
    weight = prefs.getDouble('weight');
    height = prefs.getDouble('height');
    age = prefs.getInt('age');
    bloodGroup = prefs.getString('bloodGroup');
  }

  // Save preferences to local storage
  Future<void> savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('username', username ?? '');
    await prefs.setString('school', school ?? '');
    await prefs.setDouble('budget', budget ?? 0.0);
    await prefs.setStringList('favoritedOptions', favoritedOptions.toList());
    await prefs.setString('subscriptionTier', subscriptionTier);
    if (phoneNumber != null) {
      await prefs.setString('phoneNumber', phoneNumber!);
    } else {
      await prefs.remove('phoneNumber');
    }
    if (weight != null) {
      await prefs.setDouble('weight', weight!);
    } else {
      await prefs.remove('weight');
    }
    if (height != null) {
      await prefs.setDouble('height', height!);
    } else {
      await prefs.remove('height');
    }
    if (age != null) {
      await prefs.setInt('age', age!);
    } else {
      await prefs.remove('age');
    }
    if (bloodGroup != null) {
      await prefs.setString('bloodGroup', bloodGroup!);
    } else {
      await prefs.remove('bloodGroup');
    }
  }
}
