// lib/widgets/universal_profile_card.dart
import 'package:allowance/screens/chat/individual_chat_screen.dart';
import 'package:allowance/services/subscription_service.dart'; // New Import
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';

class UniversalProfileCard extends StatefulWidget {
  final String targetUserId;
  const UniversalProfileCard({super.key, required this.targetUserId});

  static void show(BuildContext context, String userId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, scrollController) =>
            UniversalProfileCard(targetUserId: userId),
      ),
    );
  }

  @override
  State<UniversalProfileCard> createState() => _UniversalProfileCardState();
}

class _UniversalProfileCardState extends State<UniversalProfileCard> {
  final supabase = Supabase.instance.client;
  final Color themeColor = const Color(0xFF4CAF50);

  Map<String, dynamic>? _profile;
  int _followerCount = 0;
  int _totalMemoriesCount = 0;
  bool _isFollowing = false;
  List<dynamic> _memories = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadProfileData();
  }

  Future<void> _loadProfileData() async {
    final currentUserId = supabase.auth.currentUser?.id;
    if (currentUserId == null) return;
    try {
      final results = await Future.wait<dynamic>([
        supabase
            .from('profiles')
            .select()
            .eq('id', widget.targetUserId)
            .maybeSingle(),
        supabase
            .from('followers')
            .select('*')
            .eq('following_id', widget.targetUserId)
            .count(CountOption.exact),
        supabase
            .from('followers')
            .select()
            .eq('follower_id', currentUserId)
            .eq('following_id', widget.targetUserId)
            .maybeSingle(),
        supabase
            .from('memories')
            .select('*')
            .eq('user_id', widget.targetUserId)
            .count(CountOption.exact),
      ]);

      final profileResp = results[0] as Map<String, dynamic>?;
      final followersResp = results[1] as PostgrestResponse;
      final followingResp = results[2];
      final memoriesResp = results[3] as PostgrestResponse;

      final isPrivate = profileResp?['is_private'] == true;
      final isFollowingStatus = followingResp != null;
      final isMe = currentUserId == widget.targetUserId;

      List<dynamic> fetchedMemories = [];
      if (!isPrivate || isFollowingStatus || isMe) {
        fetchedMemories = await supabase
            .from('memories')
            .select()
            .eq('user_id', widget.targetUserId)
            .order('created_at', ascending: false)
            .limit(12);
      }

      if (mounted) {
        setState(() {
          _profile = profileResp;
          _followerCount = followersResp.count ?? 0;
          _totalMemoriesCount = memoriesResp.count ?? 0;
          _isFollowing = isFollowingStatus;
          _memories = fetchedMemories;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("Profile load error: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _toggleFollow() async {
    final currentUserId = supabase.auth.currentUser?.id;
    if (currentUserId == null) return;

    final wasFollowing = _isFollowing;
    setState(() {
      _isFollowing = !_isFollowing;
      _followerCount += _isFollowing ? 1 : -1;
    });
    try {
      if (!wasFollowing) {
        await supabase.from('followers').insert({
          'follower_id': currentUserId,
          'following_id': widget.targetUserId,
        });
      } else {
        await supabase.from('followers').delete().match({
          'follower_id': currentUserId,
          'following_id': widget.targetUserId,
        });
      }
    } catch (e) {
      setState(() {
        _isFollowing = wasFollowing;
        _followerCount += _isFollowing ? 1 : -1;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return _buildShell(const Center(
          child: CircularProgressIndicator(color: Color(0xFF4CAF50))));
    }

    if (_profile == null) {
      return _buildShell(const Center(
          child:
              Text("User not found", style: TextStyle(color: Colors.white))));
    }

    final isPrivate = _profile!['is_private'] == true;
    final isMe = supabase.auth.currentUser?.id == widget.targetUserId;
    final canSeeContent = !isPrivate || _isFollowing || isMe;

    return _buildShell(
      ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        children: [
          Row(
            children: [
              _buildAvatar(),
              const SizedBox(width: 20),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildStatColumn('Followers', _followerCount.toString()),
                    _buildStatColumn(
                        'Memories',
                        (isPrivate && !_isFollowing && !isMe)
                            ? '?'
                            : _totalMemoriesCount.toString()),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildProfileInfo(isPrivate),
          const SizedBox(height: 20),
          if (!isMe) _buildActionButtons(),
          const SizedBox(height: 24),
          const Divider(color: Colors.white10),
          const SizedBox(height: 12),
          const Text('Memories',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          _buildMemoriesGrid(canSeeContent),
        ],
      ),
    );
  }

  Widget _buildShell(Widget child) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 16),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
                color: Colors.white24, borderRadius: BorderRadius.circular(2)),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _buildAvatar() {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: themeColor.withOpacity(0.5), width: 2),
      ),
      child: CircleAvatar(
        radius: 40,
        backgroundColor: Colors.grey[800],
        backgroundImage: _profile!['avatar_url'] != null
            ? NetworkImage(_profile!['avatar_url'])
            : null,
        child: _profile!['avatar_url'] == null
            ? const Icon(Icons.person, size: 40, color: Colors.white54)
            : null,
      ),
    );
  }

  Widget _buildProfileInfo(bool isPrivate) {
    // Check if this specific profile is a Plus member
    final bool isPlusMember =
        SubscriptionService.isPlus(_profile!['subscription_tier']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('@${_profile!['username']}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold)),

            // STAR BADGE FOR PLUS USERS
            if (isPlusMember) ...[
              const SizedBox(width: 6),
              SubscriptionService.getPlusBadge(),
            ],

            if (isPrivate) ...[
              const SizedBox(width: 6),
              const Icon(Icons.lock, color: Colors.white54, size: 16)
            ],
          ],
        ),
        if (_profile!['school_name'] != null)
          Text(_profile!['school_name'],
              style: const TextStyle(color: Colors.white54, fontSize: 14)),
        if (_profile!['bio'] != null && _profile!['bio'].toString().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_profile!['bio'],
                style: const TextStyle(color: Colors.white, fontSize: 15)),
          ),
      ],
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _toggleFollow,
            icon: Icon(
              _isFollowing ? Icons.check : Icons.person_add_alt_1,
              size: 18,
              color: Colors.white,
            ),
            label: Text(_isFollowing ? 'Following' : 'Follow'),
            style: ElevatedButton.styleFrom(
              backgroundColor: _isFollowing ? Colors.grey[800] : themeColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: () async {
              final navigator = Navigator.of(context);
              final scaffoldMessenger = ScaffoldMessenger.of(context);
              final currentUserId = supabase.auth.currentUser?.id;

              if (currentUserId == null) return;
              try {
                final response = await supabase.rpc(
                  'get_or_create_personal_chat',
                  params: {
                    'user_a': currentUserId,
                    'user_b': widget.targetUserId,
                  },
                );
                if (response == null) throw "Could not initialize chat.";

                final String chatId = response.toString();
                if (chatId != "null" && chatId.isNotEmpty) {
                  navigator.pop();
                  navigator.push(
                    MaterialPageRoute(
                      builder: (_) => IndividualChatScreen(
                        chatId: chatId,
                        recipientProfile: _profile!,
                      ),
                    ),
                  );
                }
              } catch (e) {
                debugPrint("Navigation Error: $e");
                scaffoldMessenger.showSnackBar(
                  SnackBar(content: Text("Error: ${e.toString()}")),
                );
              }
            },
            icon: const Icon(Icons.chat_bubble_outline,
                size: 18, color: Colors.black),
            label: const Text('Message'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMemoriesGrid(bool canSeeContent) {
    if (!canSeeContent) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: Column(
            children: [
              Icon(Icons.lock_outline, color: Colors.white24, size: 64),
              SizedBox(height: 12),
              Text('This account is private.',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
              Text('Follow them to see their memories.',
                  style: TextStyle(color: Colors.white54)),
            ],
          ),
        ),
      );
    }

    if (_memories.isEmpty) {
      return const Center(
          child: Padding(
              padding: EdgeInsets.all(32),
              child: Text('No memories yet.',
                  style: TextStyle(color: Colors.white54))));
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3, crossAxisSpacing: 2, mainAxisSpacing: 2),
      itemCount: _memories.length,
      itemBuilder: (context, index) {
        final mem = _memories[index];
        return ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Stack(
            fit: StackFit.expand,
            children: [
              CachedNetworkImage(
                  imageUrl: mem['media_url'],
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(color: Colors.grey[800])),
              if (mem['media_type'] == 'video')
                const Positioned(
                    top: 4,
                    right: 4,
                    child: Icon(Icons.play_circle_fill,
                        color: Colors.white, size: 20)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatColumn(String label, String count) {
    return Column(
      children: [
        Text(count,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold)),
        Text(label,
            style: const TextStyle(color: Colors.white54, fontSize: 14)),
      ],
    );
  }
}
