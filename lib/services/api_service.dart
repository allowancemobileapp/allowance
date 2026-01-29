// lib/services/api_service.dart

import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  // Replace with your Supabase REST URL.
  static const String baseUrl =
      "https://quuazutreaitqoquzolg.supabase.co/rest/v1";

  // Your Supabase anon key.
  static const Map<String, String> headers = {
    "apikey":
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InF1dWF6dXRyZWFpdHFvcXV6b2xnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NDQwODk2MTgsImV4cCI6MjA1OTY2NTYxOH0.kVZLSMgt05gpVhtADOuI6nbHoDdVmAUnSWpsF9-iU5U",
    "Authorization":
        "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InF1dWF6dXRyZWFpdHFvcXV6b2xnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NDQwODk2MTgsImV4cCI6MjA1OTY2NTYxOH0.kVZLSMgt05gpVhtADOuI6nbHoDdVmAUnSWpsF9-iU5U",
    "Content-Type": "application/json",
  };

  /// Fetch the list of schools (universities)
  static Future<List<dynamic>> fetchSchools() async {
    final response = await http.get(
      Uri.parse("$baseUrl/schools?select=*"),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return json.decode(response.body) as List<dynamic>;
    } else {
      throw Exception("Failed to load schools: ${response.statusCode}");
    }
  }

  /// Fetch vendors for a given school.
  /// Now expects schoolId (as String) and filters on `school_id`.
  static Future<List<dynamic>> fetchVendors(String schoolId) async {
    final response = await http.get(
      Uri.parse("$baseUrl/vendors?school_id=eq.$schoolId&select=*"),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return json.decode(response.body) as List<dynamic>;
    } else {
      throw Exception(
          "Failed to load vendors for school '$schoolId': ${response.statusCode}");
    }
  }

  /// Fetch available options along with vendor name.
  static Future<List<dynamic>> fetchOptions(String schoolId) async {
    if (schoolId.isEmpty) {
      throw Exception('School ID is required to load menu');
    }
    final response = await http.get(
      Uri.parse(
          "$baseUrl/options?select=*,vendors(name)&vendors.school_id=eq.$schoolId"),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return json.decode(response.body) as List<dynamic>;
    } else {
      throw Exception(
          "Failed to load menu for school $schoolId: ${response.statusCode} - ${response.body}");
    }
  }

  /// Fetch food groups.
  static Future<List<dynamic>> fetchFoodGroups() async {
    final response = await http.get(
      Uri.parse("$baseUrl/food_groups?select=*"),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return json.decode(response.body) as List<dynamic>;
    } else {
      throw Exception("Failed to load food groups: ${response.statusCode}");
    }
  }

  /// Fetch delivery personnel for a given school ID.
  static Future<List<dynamic>> fetchDeliveryPersonnel(String schoolId) async {
    final response = await http.get(
      Uri.parse("$baseUrl/delivery_personnel?school_id=eq.$schoolId&select=*"),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return json.decode(response.body) as List<dynamic>;
    } else {
      throw Exception(
          "Failed to load delivery personnel for school '$schoolId': ${response.statusCode}");
    }
  }
}
