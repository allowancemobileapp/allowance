// lib/screens/home/single_gist_screen.dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';

class SingleGistScreen extends StatefulWidget {
  final String gistId;
  const SingleGistScreen({super.key, required this.gistId});

  @override
  State<SingleGistScreen> createState() => _SingleGistScreenState();
}

class _SingleGistScreenState extends State<SingleGistScreen> {
  final supabase = Supabase.instance.client;
  bool _isLoading = true;
  Map<String, dynamic>? _gist;

  @override
  void initState() {
    super.initState();
    _fetchGist();
  }

  Future<void> _fetchGist() async {
    try {
      final data = await supabase
          .from('gists')
          .select('*, profiles:user_id(username, avatar_url)')
          .eq('id', widget.gistId)
          .maybeSingle();

      if (mounted) {
        setState(() {
          _gist = data;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body:
            Center(child: CircularProgressIndicator(color: Color(0xFF4CAF50))),
      );
    }

    if (_gist == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
            backgroundColor: Colors.black,
            iconTheme: const IconThemeData(color: Colors.white)),
        body: const Center(
            child: Text("Gist not found or deleted.",
                style: TextStyle(color: Colors.white70, fontSize: 18))),
      );
    }

    final imageUrl = _gist!['image_url'] ?? '';
    final title = _gist!['title'] ?? '';
    final profile = _gist!['profiles'] ?? {};

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text("Gist", style: TextStyle(color: Colors.white)),
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (imageUrl.isNotEmpty)
              CachedNetworkImage(
                imageUrl: imageUrl,
                width: double.infinity,
                fit: BoxFit.cover,
                placeholder: (context, url) =>
                    Container(height: 300, color: Colors.grey[900]),
              ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: Colors.grey[800],
                        backgroundImage: profile['avatar_url'] != null
                            ? CachedNetworkImageProvider(profile['avatar_url'])
                            : null,
                        child: profile['avatar_url'] == null
                            ? const Icon(Icons.person, color: Colors.white)
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Text('@${profile['username'] ?? 'User'}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16)),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 18, height: 1.5)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
