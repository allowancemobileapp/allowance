// lib/screens/chat/group_invite_screen.dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/screens/chat/chat_room_screen.dart';

class GroupInviteScreen extends StatefulWidget {
  final String chatId;
  final UserPreferences userPreferences;

  const GroupInviteScreen({
    super.key,
    required this.chatId,
    required this.userPreferences,
  });

  @override
  State<GroupInviteScreen> createState() => _GroupInviteScreenState();
}

class _GroupInviteScreenState extends State<GroupInviteScreen> {
  final supabase = Supabase.instance.client;
  bool _isLoading = true;
  bool _isJoining = false;
  String? _error;
  Map<String, dynamic>? _chat;
  bool _alreadyMember = false;
  int _memberCount = 0;

  @override
  void initState() {
    super.initState();
    _loadGroupPreview();
  }

  Future<void> _loadGroupPreview() async {
    final myId = supabase.auth.currentUser?.id;
    if (myId == null) {
      setState(() {
        _isLoading = false;
        _error = 'Please log in first.';
      });
      return;
    }

    try {
      final chatResp = await supabase
          .from('chats')
          .select('*, chat_participants(user_id)')
          .eq('id', widget.chatId)
          .maybeSingle();

      if (chatResp == null) {
        setState(() {
          _isLoading = false;
          _error = 'This invite link is no longer valid.';
        });
        return;
      }

      final rules = chatResp['rules'] as Map<String, dynamic>? ?? {};
      final isGroup = chatResp['is_group'] == true;
      final linkEnabled = rules['share_link'] == true;
      final participants =
          List<Map<String, dynamic>>.from(chatResp['chat_participants'] ?? []);
      final alreadyIn =
          participants.any((p) => p['user_id']?.toString() == myId);

      if (!isGroup || (!linkEnabled && !alreadyIn)) {
        setState(() {
          _isLoading = false;
          _error = 'This invite link has been disabled by the group.';
        });
        return;
      }

      setState(() {
        _chat = chatResp;
        _memberCount = participants.length;
        _alreadyMember = alreadyIn;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = 'Could not load this invite.';
      });
    }
  }

  Future<void> _joinGroup() async {
    final myId = supabase.auth.currentUser?.id;
    if (myId == null || _chat == null) return;

    setState(() => _isJoining = true);
    try {
      await supabase.from('chat_participants').insert({
        'chat_id': widget.chatId,
        'user_id': myId,
      });

      final myUsername = widget.userPreferences.username ?? 'Someone';
      await supabase.from('messages').insert({
        'chat_id': widget.chatId,
        'sender_id': myId,
        'content': '@$myUsername joined via invite link',
        'media_type': 'system',
        'is_read': true,
      });

      if (mounted) _openChat();
    } catch (e) {
      if (mounted) {
        setState(() => _isJoining = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('Failed to join group. It may no longer be available.')),
        );
      }
    }
  }

  void _openChat() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ChatRoomScreen(
          chatId: widget.chatId,
          chatTitle: _chat?['group_name'] ?? _chat?['name'] ?? 'Group',
          isAdmin: false,
          userPreferences: widget.userPreferences,
          isGroup: true,
          creatorId:
              (_chat?['admin_id'] ?? _chat?['created_by'] ?? _chat?['owner_id'])
                  ?.toString(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF121212),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: _isLoading
            ? const CircularProgressIndicator(color: Color(0xFF4CAF50))
            : _error != null
                ? Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.link_off,
                            color: Colors.white38, size: 48),
                        const SizedBox(height: 16),
                        Text(_error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 16)),
                      ],
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 48,
                          backgroundColor: Colors.grey[800],
                          backgroundImage: _chat?['group_avatar'] != null
                              ? NetworkImage(_chat!['group_avatar'])
                              : null,
                          child: _chat?['group_avatar'] == null
                              ? const Icon(Icons.groups,
                                  size: 48, color: Colors.white54)
                              : null,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          _chat?['group_name'] ??
                              _chat?['name'] ??
                              'Group Chat',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text('$_memberCount members',
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 14)),
                        if (_chat?['group_description']
                                ?.toString()
                                .isNotEmpty ==
                            true) ...[
                          const SizedBox(height: 12),
                          Text(_chat!['group_description'],
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white70)),
                        ],
                        const SizedBox(height: 32),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF4CAF50),
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                            ),
                            onPressed: _isJoining
                                ? null
                                : (_alreadyMember ? _openChat : _joinGroup),
                            child: _isJoining
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                        color: Colors.black, strokeWidth: 2))
                                : Text(
                                    _alreadyMember ? 'Open Chat' : 'Join Group',
                                    style: const TextStyle(
                                        color: Colors.black,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
      ),
    );
  }
}
