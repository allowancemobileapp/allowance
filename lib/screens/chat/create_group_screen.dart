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
  final bool isEdit;
  final String? chatId;
  final String? initialName;
  final String? initialAvatarUrl;
  final String? initialDescription;

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

  // Themes
  final List<String> _kGroupThemes = [
    'Educational',
    'Random',
    'Tech',
    'Relationship',
    'Wildlife',
    'Deep Sea',
    'Funny',
    'Religion',
    'Games',
    'News',
    'Art',
    'Showbiz',
    'Food',
    'Sports',
    'AI Madness',
    'Brain Rot',
  ];
  List<String> _selectedThemes = [];

  // Text Rules
  final _customRuleCtrl = TextEditingController();
  List<String> _customRules = [];

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
              'group_name, group_description, group_avatar, rules, is_public, themes, custom_rules')
          .eq('id', widget.chatId!)
          .single();
      final participants = await _supabase
          .from('chat_participants')
          .select('user_id')
          .eq('chat_id', widget.chatId!);

      setState(() {
        _nameController.text = groupData['group_name'] ?? '';
        _descController.text = groupData['group_description'] ?? '';
        _isPublic = groupData['is_public'] ?? true;
        _selectedThemes = List<String>.from(
            (groupData['themes'] as List?)?.map((e) => e.toString()) ?? []);
        _customRules = List<String>.from(
            (groupData['custom_rules'] as List?)?.map((e) => e.toString()) ??
                []);

        _selectedUserIds.clear();
        for (var p in participants)
          _selectedUserIds.add(p['user_id'].toString());

        final rules = groupData['rules'] as Map<String, dynamic>? ?? {};
        _onlyAdminsChat = rules['only_admins_chat'] ?? false;
        _allowShareLink = rules['share_link'] ?? false;
        _allowPhotos = rules['photos'] ?? true;
        _allowVideos = rules['videos'] ?? true;
        _allowLinks = rules['links'] ?? true;
        _allowFiles = rules['files'] ?? true;
        _timeLock = rules['time_lock'] ?? false;

        if (rules['open_time'] != null) {
          final pts = rules['open_time'].toString().split(':');
          if (pts.length == 2)
            _openTime =
                TimeOfDay(hour: int.parse(pts[0]), minute: int.parse(pts[1]));
        }
        if (rules['close_time'] != null) {
          final pts = rules['close_time'].toString().split(':');
          if (pts.length == 2)
            _closeTime =
                TimeOfDay(hour: int.parse(pts[0]), minute: int.parse(pts[1]));
        }
      });
    } catch (e) {
      debugPrint("Failed to load existing group data: $e");
    }
  }

  Future<void> _fetchFriends() async {
    final myId = _supabase.auth.currentUser?.id;
    if (myId == null) {
      setState(() => _isLoading = false);
      return;
    }
    try {
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
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _pickAvatar() async {
    final picked = await ImagePicker()
        .pickImage(source: ImageSource.gallery, imageQuality: 70);
    if (picked != null && mounted) setState(() => _pickedAvatar = picked);
  }

  // 🔥 FIX: Now properly referenced from the Time Lock Switch!
  Future<void> _selectTimeLock() async {
    final open = await showTimePicker(
        context: context,
        initialTime: const TimeOfDay(hour: 8, minute: 0),
        helpText: 'OPENING TIME');
    if (open == null) {
      setState(() => _timeLock = false);
      return;
    }
    if (!mounted) return;
    final close = await showTimePicker(
        context: context,
        initialTime: const TimeOfDay(hour: 22, minute: 0),
        helpText: 'CLOSING TIME');
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

      final payload = {
        'group_name': _nameController.text.trim(),
        'group_description': _descController.text.trim(),
        if (avatarUrl != null) 'group_avatar': avatarUrl,
        'rules': rules,
        'is_public': _isPublic,
        'themes': _selectedThemes,
        'custom_rules': _customRules,
      };

      if (widget.isEdit && widget.chatId != null) {
        payload['updated_at'] = DateTime.now().toUtc().toIso8601String();
        await _supabase.from('chats').update(payload).eq('id', widget.chatId!);

        if (_selectedUserIds.isNotEmpty) {
          final currentMembers = await _supabase
              .from('chat_participants')
              .select('user_id')
              .eq('chat_id', widget.chatId!);
          final existingIds =
              currentMembers.map((m) => m['user_id'].toString()).toSet();
          final newParticipants = _selectedUserIds
              .where((id) => !existingIds.contains(id))
              .map((id) =>
                  {'chat_id': widget.chatId!, 'user_id': id, 'role': 'member'})
              .toList();
          if (newParticipants.isNotEmpty)
            await _supabase.from('chat_participants').insert(newParticipants);
        }
        if (mounted) {
          Navigator.pop(context, true);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text("Group updated!"), backgroundColor: Colors.green));
        }
      } else {
        payload['is_group'] = true;
        payload['admin_id'] = myId;
        final chat =
            await _supabase.from('chats').insert(payload).select().single();
        final chatId = chat['id'];

        final List<Map<String, dynamic>> participants = _selectedUserIds
            .map((id) => {'chat_id': chatId, 'user_id': id, 'role': 'member'})
            .toList();
        participants.add({'chat_id': chatId, 'user_id': myId, 'role': 'admin'});
        await _supabase.from('chat_participants').insert(participants);

        if (mounted) {
          Navigator.pop(context, true);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text("Group created!"), backgroundColor: Colors.green));
        }
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.userPreferences.subscriptionTier != 'Membership') {
      return Scaffold(
        backgroundColor: const Color(0xFF121212),
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
                  onPressed: () => Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                          builder: (_) => SubscriptionScreen(
                              userPreferences: widget.userPreferences,
                              themeColor: themeColor))),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: themeColor,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 32, vertical: 12)),
                  child: const Text('Upgrade to Plus',
                      style: TextStyle(
                          color: Colors.black, fontWeight: FontWeight.bold)),
                )
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF121212),
        title: Text(widget.isEdit ? "Edit Group" : "New Group",
            style: const TextStyle(color: Colors.white)),
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
                child: Text(widget.isEdit ? "SAVE" : "CREATE",
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF4CAF50)))),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF4CAF50)))
          : ListView(
              padding: const EdgeInsets.all(16.0),
              children: [
                Row(
                  children: [
                    GestureDetector(
                      onTap: _pickAvatar,
                      child: CircleAvatar(
                        radius: 35,
                        backgroundColor: const Color(0xFF1E1E1E),
                        backgroundImage: _pickedAvatar != null
                            ? (kIsWeb
                                    ? NetworkImage(_pickedAvatar!.path)
                                    : FileImage(File(_pickedAvatar!.path)))
                                as ImageProvider
                            : (widget.initialAvatarUrl != null
                                ? NetworkImage(widget.initialAvatarUrl!)
                                : null),
                        child: _pickedAvatar == null &&
                                widget.initialAvatarUrl == null
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
                                labelStyle:
                                    const TextStyle(color: Colors.white54),
                                filled: true,
                                fillColor: const Color(0xFF1E1E1E),
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: BorderSide.none)))),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                    controller: _descController,
                    style: const TextStyle(color: Colors.white),
                    maxLines: 2,
                    decoration: InputDecoration(
                        labelText: "Description (Optional)",
                        labelStyle: const TextStyle(color: Colors.white54),
                        filled: true,
                        fillColor: const Color(0xFF1E1E1E),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none))),
                const SizedBox(height: 24),
                const Text("Group Themes (Max 3)",
                    style: TextStyle(
                        color: Color(0xFF4CAF50),
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _kGroupThemes.map((t) {
                    final isSel = _selectedThemes.contains(t);
                    return FilterChip(
                        label: Text(t,
                            style: TextStyle(
                                color: isSel ? Colors.black : Colors.white70)),
                        selected: isSel,
                        selectedColor: themeColor,
                        backgroundColor: const Color(0xFF1E1E1E),
                        onSelected: (v) {
                          setState(() {
                            if (v && _selectedThemes.length < 3)
                              _selectedThemes.add(t);
                            else
                              _selectedThemes.remove(t);
                          });
                        });
                  }).toList(),
                ),
                const SizedBox(height: 24),
                const Text("Group Guidelines (Text)",
                    style: TextStyle(
                        color: Color(0xFF4CAF50),
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(12)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                              child: TextField(
                                  controller: _customRuleCtrl,
                                  style: const TextStyle(color: Colors.white),
                                  decoration: const InputDecoration(
                                      hintText: 'Add a rule (e.g. No spam)',
                                      hintStyle:
                                          TextStyle(color: Colors.white38),
                                      filled: true,
                                      fillColor: Color(0xFF121212),
                                      border: InputBorder.none))),
                          IconButton(
                              icon: const Icon(Icons.add_circle,
                                  color: Color(0xFF4CAF50)),
                              onPressed: () {
                                if (_customRuleCtrl.text.isNotEmpty)
                                  setState(() {
                                    _customRules.add(_customRuleCtrl.text);
                                    _customRuleCtrl.clear();
                                  });
                              })
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                          spacing: 8,
                          children: _customRules
                              .map((r) => Chip(
                                  label: Text(r,
                                      style: const TextStyle(
                                          color: Colors.white, fontSize: 12)),
                                  backgroundColor: const Color(0xFF121212),
                                  onDeleted: () =>
                                      setState(() => _customRules.remove(r))))
                              .toList()),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                const Text("Privacy & Access",
                    style: TextStyle(
                        color: Color(0xFF4CAF50),
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(12)),
                  child: Column(
                    children: [
                      RadioListTile<bool>(
                          title: const Text('Public Group',
                              style: TextStyle(color: Colors.white)),
                          subtitle: const Text(
                              'Anyone can search for and join via Explore.',
                              style: TextStyle(
                                  color: Colors.white54, fontSize: 12)),
                          value: true,
                          groupValue: _isPublic,
                          activeColor: themeColor,
                          onChanged: (val) => setState(() => _isPublic = val!)),
                      RadioListTile<bool>(
                          title: const Text('Private Group',
                              style: TextStyle(color: Colors.white)),
                          subtitle: const Text(
                              'Hidden from Explore. Admin invite only.',
                              style: TextStyle(
                                  color: Colors.white54, fontSize: 12)),
                          value: false,
                          groupValue: _isPublic,
                          activeColor: themeColor,
                          onChanged: (val) => setState(() => _isPublic = val!)),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                const Text("Group Chat Settings",
                    style: TextStyle(
                        color: Color(0xFF4CAF50),
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(12)),
                  child: Column(
                    children: [
                      SwitchListTile(
                          title: const Text("Only Admins can chat",
                              style: TextStyle(color: Colors.white)),
                          activeColor: themeColor,
                          value: _onlyAdminsChat,
                          onChanged: (v) =>
                              setState(() => _onlyAdminsChat = v)),
                      SwitchListTile(
                          title: const Text("Allow sharing Group Link",
                              style: TextStyle(color: Colors.white)),
                          activeColor: themeColor,
                          value: _allowShareLink,
                          onChanged: (v) =>
                              setState(() => _allowShareLink = v)),
                      SwitchListTile(
                          title: const Text("Allow Photos",
                              style: TextStyle(color: Colors.white)),
                          activeColor: themeColor,
                          value: _allowPhotos,
                          onChanged: (v) => setState(() => _allowPhotos = v)),
                      SwitchListTile(
                          title: const Text("Allow Videos",
                              style: TextStyle(color: Colors.white)),
                          activeColor: themeColor,
                          value: _allowVideos,
                          onChanged: (v) => setState(() => _allowVideos = v)),
                      SwitchListTile(
                          title: const Text("Allow Links",
                              style: TextStyle(color: Colors.white)),
                          activeColor: themeColor,
                          value: _allowLinks,
                          onChanged: (v) => setState(() => _allowLinks = v)),
                      SwitchListTile(
                          title: const Text("Allow Files",
                              style: TextStyle(color: Colors.white)),
                          activeColor: themeColor,
                          value: _allowFiles,
                          onChanged: (v) => setState(() => _allowFiles = v)),
                      SwitchListTile(
                        title: const Text("Time Lock",
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
                          if (v)
                            _selectTimeLock();
                          else
                            setState(() {
                              _timeLock = false;
                              _openTime = null;
                              _closeTime = null;
                            });
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                const Text("Add Members",
                    style: TextStyle(
                        color: Color(0xFF4CAF50),
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(12)),
                  child: _friends.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(
                              child: Text("You don't follow anyone yet.",
                                  style: TextStyle(color: Colors.white54))))
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
                                  backgroundColor: const Color(0xFF121212),
                                  backgroundImage: user['avatar_url'] != null
                                      ? NetworkImage(user['avatar_url'])
                                      : null,
                                  child: user['avatar_url'] == null
                                      ? const Icon(Icons.person,
                                          color: Colors.white54)
                                      : null),
                              activeColor: themeColor,
                              checkColor: Colors.black,
                              value: isSelected,
                              onChanged: (val) {
                                setState(() {
                                  if (val == true)
                                    _selectedUserIds.add(userId);
                                  else
                                    _selectedUserIds.remove(userId);
                                });
                              },
                            );
                          },
                        ),
                ),
                const SizedBox(height: 40),
              ],
            ),
    );
  }
}
