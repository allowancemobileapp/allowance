// lib/screens/chat/create_group_screen.dart
import 'dart:io';
import 'package:allowance/screens/home/subscription_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../models/user_preferences.dart';

class CreateGroupScreen extends StatefulWidget {
  final UserPreferences userPreferences;
  final bool isEdit; // ← NEW
  final String? chatId; // ← NEW
  final String? initialName; // ← NEW
  final String? initialAvatarUrl; // ← NEW
  final String? initialDescription; // ← NEW

  const CreateGroupScreen({
    super.key,
    required this.userPreferences,
    this.isEdit = false,
    this.chatId,
    this.initialName,
    this.initialAvatarUrl,
    this.initialDescription,
  });

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _supabase = Supabase.instance.client;
  final Color themeColor = const Color(0xFF4CAF50);

  // Group Details
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  bool _isPublic = true;
  XFile? _pickedAvatar;

  // Group Rules
  bool _onlyAdminsChat = false;
  bool _allowShareLink = false;
  bool _allowPhotos = true;
  bool _allowVideos = true;
  bool _allowLinks = true;
  bool _allowFiles = true;
  bool _timeLock = false;
  TimeOfDay? _openTime;
  TimeOfDay? _closeTime;

  // Friends & State
  List<Map<String, dynamic>> _friends = [];
  final Set<String> _selectedUserIds = {};
  bool _isLoading = true;
  bool _isCreating = false;

  @override
  void initState() {
    super.initState();
    if (widget.isEdit) {
      _loadExistingGroupData();
    }
    _fetchFriends();
  }

  Future<void> _loadExistingGroupData() async {
    if (widget.chatId == null) return;

    try {
      final groupData = await _supabase
          .from('chats')
          .select(
              'group_name, group_description, group_avatar, rules, is_public')
          .eq('id', widget.chatId!)
          .single();

      // Load existing participants
      final participants = await _supabase
          .from('chat_participants')
          .select('user_id')
          .eq('chat_id', widget.chatId!);

      setState(() {
        _nameController.text = groupData['group_name'] ?? '';
        _descController.text = groupData['group_description'] ?? '';
        _isPublic = groupData['is_public'] ?? true;

        // Pre-select existing members
        _selectedUserIds.clear();
        for (var p in participants) {
          _selectedUserIds.add(p['user_id'].toString());
        }

        // Load Rules
        final rules = groupData['rules'] as Map<String, dynamic>? ?? {};
        _onlyAdminsChat = rules['only_admins_chat'] ?? false;
        _allowShareLink = rules['share_link'] ?? false;
        _allowPhotos = rules['photos'] ?? true;
        _allowVideos = rules['videos'] ?? true;
        _allowLinks = rules['links'] ?? true;
        _allowFiles = rules['files'] ?? true;
        _timeLock = rules['time_lock'] ?? false;
      });
    } catch (e) {
      debugPrint("Failed to load existing group data: $e");
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  Future<void> _fetchFriends() async {
    final myId = _supabase.auth.currentUser?.id;
    if (myId == null) {
      setState(() => _isLoading = false);
      return;
    }

    try {
      // Simplified + more reliable query
      final friendsData = await _supabase
          .from('profiles')
          .select('id, username, avatar_url, school_name')
          .inFilter(
              'id',
              await _supabase
                  .from('followers')
                  .select('following_id')
                  .eq('follower_id', myId)
                  .then((res) =>
                      res.map((r) => r['following_id'].toString()).toList()));

      setState(() {
        _friends = List<Map<String, dynamic>>.from(friendsData);
        debugPrint("✅ Fetched ${_friends.length} friends successfully");
        _isLoading = false;
      });
    } catch (e) {
      debugPrint("Fetch friends error: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _pickAvatar() async {
    final picker = ImagePicker();
    final picked =
        await picker.pickImage(source: ImageSource.gallery, imageQuality: 70);
    if (picked != null && mounted) setState(() => _pickedAvatar = picked);
  }

  Future<void> _selectTimeLock() async {
    final open = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 8, minute: 0),
      helpText: 'SELECT OPENING TIME',
    );
    if (open == null) {
      setState(() => _timeLock = false);
      return;
    }

    if (!mounted) return;
    final close = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 22, minute: 0),
      helpText: 'SELECT CLOSING TIME',
    );

    if (close == null) {
      setState(() => _timeLock = false);
      return;
    }

    setState(() {
      _openTime = open;
      _closeTime = close;
      _timeLock = true;
    });
  }

  Future<String?> _uploadAvatar() async {
    if (_pickedAvatar == null) return null;
    try {
      final bytes = await _pickedAvatar!.readAsBytes();
      final ext = _pickedAvatar!.name.split('.').last;
      final path = 'group_avatars/${const Uuid().v4()}.$ext';

      await _supabase.storage.from('avatars').uploadBinary(path, bytes);
      return _supabase.storage.from('avatars').getPublicUrl(path);
    } catch (e) {
      debugPrint("Avatar Upload Error: $e");
      return null;
    }
  }

  Future<void> _createGroup() async {
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Group name is required!")));
      return;
    }

    setState(() => _isCreating = true);
    final myId = _supabase.auth.currentUser!.id;

    try {
      final avatarUrl = await _uploadAvatar();

      final rules = {
        "only_admins_chat": _onlyAdminsChat,
        "share_link": _allowShareLink,
        "photos": _allowPhotos,
        "videos": _allowVideos,
        "links": _allowLinks,
        "files": _allowFiles,
        "time_lock": _timeLock,
        "open_time": _timeLock && _openTime != null
            ? "${_openTime!.hour}:${_openTime!.minute}"
            : null,
        "close_time": _timeLock && _closeTime != null
            ? "${_closeTime!.hour}:${_closeTime!.minute}"
            : null,
      };

      if (widget.isEdit && widget.chatId != null) {
        // === EDIT MODE ===
        final response = await _supabase
            .from('chats')
            .update({
              'group_name': _nameController.text.trim(),
              'group_description': _descController.text.trim(),
              'group_avatar': avatarUrl ?? widget.initialAvatarUrl,
              'rules': rules,
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('id', widget.chatId!)
            .select();

        // Add only NEW members (avoid duplicate key error)
        if (_selectedUserIds.isNotEmpty) {
          // Get current members
          final currentMembers = await _supabase
              .from('chat_participants')
              .select('user_id')
              .eq('chat_id', widget.chatId!);

          final existingIds =
              currentMembers.map((m) => m['user_id'].toString()).toSet();

          // Filter only new users
          final newParticipants = _selectedUserIds
              .where((id) => !existingIds.contains(id))
              .map((id) => {
                    'chat_id': widget.chatId!,
                    'user_id': id,
                    'role': 'member',
                  })
              .toList();

          if (newParticipants.isNotEmpty) {
            await _supabase.from('chat_participants').insert(newParticipants);
          }
        }

        debugPrint("Edit Response: $response");

        if (mounted) {
          Navigator.pop(context, true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text("Group updated successfully!"),
                backgroundColor: Colors.green),
          );
        }
      } else {
        // === CREATE MODE ===
        final chat = await _supabase
            .from('chats')
            .insert({
              'is_group': true,
              'is_public': _isPublic,
              'group_name': _nameController.text.trim(),
              'group_description': _descController.text.trim(),
              'group_avatar': avatarUrl,
              'admin_id': myId,
              'rules': rules,
            })
            .select()
            .single();

        final chatId = chat['id'];

        final List<Map<String, dynamic>> participants = _selectedUserIds
            .map((id) => {
                  'chat_id': chatId,
                  'user_id': id,
                  'role': 'member',
                })
            .toList();

        participants.add({
          'chat_id': chatId,
          'user_id': myId,
          'role': 'admin',
        });

        await _supabase.from('chat_participants').insert(participants);

        if (mounted) {
          Navigator.pop(context, true);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text("Group created successfully!"),
              backgroundColor: Colors.green));
        }
      }
    } catch (e) {
      debugPrint("Group Error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 1. PLUS MEMBER PAYWALL CHECK
    final isPlus = widget.userPreferences.subscriptionTier == 'Membership';

    if (!isPlus) {
      return Scaffold(
        backgroundColor: Colors.grey[900],
        appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.group_off, size: 80, color: Colors.amber),
                const SizedBox(height: 16),
                const Text('Plus Members Only',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text(
                    'Creating groups is an exclusive feature for Allowance Plus members.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 16)),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () {
                    Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(
                            builder: (_) => SubscriptionScreen(
                                userPreferences: widget.userPreferences,
                                themeColor: themeColor)));
                  },
                  style: ElevatedButton.styleFrom(
                      backgroundColor: themeColor,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 32, vertical: 12)),
                  child: const Text('Upgrade to Plus',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                )
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        title: Text(
          widget.isEdit ? "Edit Group" : "New Group",
          style: const TextStyle(color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (_isCreating)
            const Center(
                child: Padding(
                    padding: EdgeInsets.all(16.0),
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(0xFF4CAF50)))))
          else
            TextButton(
              onPressed: _createGroup,
              child: Text(
                widget.isEdit ? "SAVE CHANGES" : "CREATE",
                style: const TextStyle(
                    fontWeight: FontWeight.bold, color: Color(0xFF4CAF50)),
              ),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF4CAF50)))
          : ListView(
              padding: const EdgeInsets.all(16.0),
              children: [
                // AVATAR & NAME
                Row(
                  children: [
                    GestureDetector(
                      onTap: _pickAvatar,
                      child: CircleAvatar(
                        radius: 35,
                        backgroundColor: Colors.grey[800],
                        backgroundImage: _pickedAvatar != null
                            ? (kIsWeb
                                    ? NetworkImage(_pickedAvatar!.path)
                                    : FileImage(File(_pickedAvatar!.path)))
                                as ImageProvider
                            : null,
                        child: _pickedAvatar == null
                            ? const Icon(Icons.camera_alt,
                                color: Colors.white54)
                            : null,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: TextField(
                        controller: _nameController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: "Group Name",
                          labelStyle: const TextStyle(color: Colors.white54),
                          filled: true,
                          fillColor: Colors.grey[900],
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // DESCRIPTION
                TextField(
                  controller: _descController,
                  style: const TextStyle(color: Colors.white),
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: "Description (Optional)",
                    labelStyle: const TextStyle(color: Colors.white54),
                    filled: true,
                    fillColor: Colors.grey[900],
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 24),

                // PRIVACY
                const Text("Privacy",
                    style: TextStyle(
                        color: Color(0xFF4CAF50),
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                      color: Colors.grey[900],
                      borderRadius: BorderRadius.circular(12)),
                  child: Column(
                    children: [
                      RadioListTile<bool>(
                        title: const Text('Public Group',
                            style: TextStyle(color: Colors.white)),
                        subtitle: const Text(
                            'Anyone can search for and join this group via the Explore page.',
                            style:
                                TextStyle(color: Colors.white54, fontSize: 12)),
                        value: true,
                        groupValue: _isPublic,
                        activeColor: themeColor,
                        onChanged: (val) => setState(() => _isPublic = val!),
                      ),
                      RadioListTile<bool>(
                        title: const Text('Private Group',
                            style: TextStyle(color: Colors.white)),
                        subtitle: const Text(
                            'Hidden from Explore. Only accessible via admin invite.',
                            style:
                                TextStyle(color: Colors.white54, fontSize: 12)),
                        value: false,
                        groupValue: _isPublic,
                        activeColor: themeColor,
                        onChanged: (val) => setState(() => _isPublic = val!),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // GROUP RULES
                const Text("Group Rules",
                    style: TextStyle(
                        color: Color(0xFF4CAF50),
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                      color: Colors.grey[900],
                      borderRadius: BorderRadius.circular(12)),
                  child: Column(
                    children: [
                      SwitchListTile(
                        title: const Text("Allow only Admins to chat",
                            style: TextStyle(color: Colors.white)),
                        activeColor: themeColor,
                        value: _onlyAdminsChat,
                        onChanged: (v) => setState(() => _onlyAdminsChat = v),
                      ),
                      SwitchListTile(
                        title: const Text("Allow sharing of Group Link",
                            style: TextStyle(color: Colors.white)),
                        activeColor: themeColor,
                        value: _allowShareLink,
                        onChanged: (v) => setState(() => _allowShareLink = v),
                      ),
                      SwitchListTile(
                        title: const Text("Allow posting of Photos",
                            style: TextStyle(color: Colors.white)),
                        activeColor: themeColor,
                        value: _allowPhotos,
                        onChanged: (v) => setState(() => _allowPhotos = v),
                      ),
                      SwitchListTile(
                        title: const Text("Allow posting of Videos",
                            style: TextStyle(color: Colors.white)),
                        activeColor: themeColor,
                        value: _allowVideos,
                        onChanged: (v) => setState(() => _allowVideos = v),
                      ),
                      SwitchListTile(
                        title: const Text("Allow posting of Links",
                            style: TextStyle(color: Colors.white)),
                        activeColor: themeColor,
                        value: _allowLinks,
                        onChanged: (v) => setState(() => _allowLinks = v),
                      ),
                      SwitchListTile(
                        title: const Text("Allow posting of Files",
                            style: TextStyle(color: Colors.white)),
                        activeColor: themeColor,
                        value: _allowFiles,
                        onChanged: (v) => setState(() => _allowFiles = v),
                      ),
                      SwitchListTile(
                        title: const Text("Lock/Open group at certain time",
                            style: TextStyle(color: Colors.white)),
                        subtitle: _timeLock && _openTime != null
                            ? Text(
                                "Opens: ${_openTime!.format(context)} | Closes: ${_closeTime!.format(context)}",
                                style: const TextStyle(
                                    color: Colors.amber, fontSize: 12))
                            : null,
                        activeColor: themeColor,
                        value: _timeLock,
                        onChanged: (v) {
                          if (v) {
                            _selectTimeLock();
                          } else {
                            setState(() {
                              _timeLock = false;
                              _openTime = null;
                              _closeTime = null;
                            });
                          }
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // ADD FRIENDS
                // ADD FRIENDS
                const Text("Add Friends",
                    style: TextStyle(
                        color: Color(0xFF4CAF50),
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
                const SizedBox(height: 8),

                // Search Bar
                TextField(
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: "Search friends...",
                    hintStyle: const TextStyle(color: Colors.white54),
                    prefixIcon: const Icon(Icons.search, color: Colors.white54),
                    filled: true,
                    fillColor: Colors.grey[850],
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (value) {
                    // You can add filtering logic here later if needed
                  },
                ),
                const SizedBox(height: 12),

                Container(
                  decoration: BoxDecoration(
                      color: Colors.grey[900],
                      borderRadius: BorderRadius.circular(12)),
                  child: _friends.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Center(
                            child: Text(
                                "You don't follow anyone yet. (${_friends.length} loaded)",
                                style: const TextStyle(color: Colors.white54)),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _friends.length,
                          itemBuilder: (context, index) {
                            final user = _friends[index];
                            final userId = user['id'].toString();
                            final isSelected =
                                _selectedUserIds.contains(userId);

                            return CheckboxListTile(
                              title: Text(user['username'] ?? "User",
                                  style: const TextStyle(color: Colors.white)),
                              subtitle: Text(user['school_name'] ?? "",
                                  style: const TextStyle(
                                      color: Colors.white54, fontSize: 12)),
                              secondary: CircleAvatar(
                                backgroundColor: Colors.grey[800],
                                backgroundImage: user['avatar_url'] != null
                                    ? NetworkImage(user['avatar_url'])
                                    : null,
                                child: user['avatar_url'] == null
                                    ? const Icon(Icons.person,
                                        color: Colors.white54)
                                    : null,
                              ),
                              activeColor: themeColor,
                              checkColor: Colors.black,
                              value: isSelected,
                              onChanged: (val) {
                                setState(() {
                                  if (val == true) {
                                    _selectedUserIds.add(userId);
                                  } else {
                                    _selectedUserIds.remove(userId);
                                  }
                                });
                              },
                            );
                          },
                        ),
                ),
                const SizedBox(height: 40), // Bottom padding
              ],
            ),
    );
  }
}
