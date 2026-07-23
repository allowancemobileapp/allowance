// lib/screens/home/single_gist_screen.dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:gal/gal.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import 'package:url_launcher/url_launcher.dart';

class SingleGistScreen extends StatefulWidget {
  final String gistId;
  const SingleGistScreen({super.key, required this.gistId});

  @override
  State<SingleGistScreen> createState() => _SingleGistScreenState();
}

class _SingleGistScreenState extends State<SingleGistScreen> {
  final supabase = Supabase.instance.client;
  final Color themeColor = const Color(0xFF4CAF50);

  bool _isLoading = true;
  Map<String, dynamic>? _gist;
  int _likeCount = 0;
  int _commentCount = 0;
  bool _isLiked = false;

  VideoPlayerController? _videoController;
  int _localPageIndex = 0;
  bool _showHeartOverlay = false;

  @override
  void initState() {
    super.initState();
    _fetchGist();
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  bool _requireAuth() {
    if (supabase.auth.currentUser == null) {
      showModalBottomSheet(
          context: context,
          backgroundColor: Colors.grey[900],
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
          builder: (ctx) => Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock_person,
                        size: 64, color: Color(0xFF4CAF50)),
                    const SizedBox(height: 16),
                    const Text('Sign in to interact',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    const Text(
                        'Join Allowance to like, comment, and connect with other students.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70)),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF4CAF50)),
                        onPressed: () {
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text(
                                      'Please log out and sign in to continue.')));
                        },
                        child: const Text('Okay',
                            style: TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.bold)),
                      ),
                    )
                  ],
                ),
              ));
      return false;
    }
    return true;
  }

  Future<void> _fetchGist() async {
    try {
      final data = await supabase
          .from('gists')
          .select('*, profiles:user_id(username, avatar_url)')
          .eq('id', widget.gistId)
          .maybeSingle();

      if (data == null) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      // Handle Video Init
      if (data['media_type'] == 'video' && data['image_url'] != null) {
        _videoController =
            VideoPlayerController.networkUrl(Uri.parse(data['image_url']))
              ..initialize().then((_) {
                if (mounted) setState(() {});
                _videoController!.setLooping(true);
                _videoController!.play();
              });
      }

      final likesRes = await supabase
          .from('gist_likes')
          .select('user_id')
          .eq('gist_id', widget.gistId);
      final commentsRes = await supabase
          .from('gist_comments')
          .select('id')
          .eq('gist_id', widget.gistId)
          .count(CountOption.exact);

      final user = supabase.auth.currentUser;
      bool liked = false;
      if (user != null) {
        liked = (likesRes as List).any((l) => l['user_id'] == user.id);
      }

      if (mounted) {
        setState(() {
          _gist = data;
          _likeCount = (likesRes as List).length;
          _commentCount = commentsRes.count;
          _isLiked = liked;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _toggleLike() async {
    if (!_requireAuth()) return;

    final user = supabase.auth.currentUser!;
    final gid = int.parse(widget.gistId);

    setState(() {
      _isLiked = !_isLiked;
      _likeCount += _isLiked ? 1 : -1;
    });

    try {
      if (_isLiked) {
        await supabase
            .from('gist_likes')
            .insert({'gist_id': gid, 'user_id': user.id});
      } else {
        await supabase
            .from('gist_likes')
            .delete()
            .eq('gist_id', gid)
            .eq('user_id', user.id);
      }
    } catch (e) {
      setState(() {
        _isLiked = !_isLiked;
        _likeCount += _isLiked ? 1 : -1;
      });
    }
  }

  void _triggerDoubleTapLike() {
    if (!_isLiked) _toggleLike();
    setState(() => _showHeartOverlay = true);
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _showHeartOverlay = false);
    });
  }

  void _expandMedia(String url) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          fit: StackFit.expand,
          children: [
            InteractiveViewer(
                panEnabled: true,
                minScale: 1.0,
                maxScale: 4.0,
                child: CachedNetworkImage(imageUrl: url, fit: BoxFit.contain)),
            Positioned(
                top: 40,
                right: 20,
                child: IconButton(
                    icon:
                        const Icon(Icons.close, color: Colors.white, size: 32),
                    onPressed: () => Navigator.pop(context))),
          ],
        ),
      ),
    );
  }

  // 🔥 FIX: Now handles both Images AND Videos safely!
  Future<void> _downloadMedia(String url, String mediaType) async {
    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final request = await Gal.requestAccess();
        if (!request) return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Downloading to gallery...')));

      final file = await DefaultCacheManager().getSingleFile(url);

      // Check if it's a video or image
      if (mediaType == 'video') {
        await Gal.putVideo(file.path);
      } else {
        await Gal.putImage(file.path);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('✅ Saved to Gallery/Photos!'),
            backgroundColor: Colors.green));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('❌ Could not save media.'),
            backgroundColor: Colors.red));
      }
    }
  }

  Future<List<dynamic>> _fetchFriends(String myId) async {
    try {
      final res = await supabase
          .from('followers')
          .select('following_id')
          .eq('follower_id', myId);
      final followingIds = res.map((e) => e['following_id']).toList();
      if (followingIds.isEmpty) return [];
      return await supabase
          .from('profiles')
          .select('id, username, avatar_url')
          .inFilter('id', followingIds);
    } catch (e) {
      return [];
    }
  }

  void _showShipSheet(BuildContext context) {
    if (!_requireAuth()) return;
    final myId = supabase.auth.currentUser?.id;
    if (myId == null) return;

    final String title = _gist?['title'] ?? '';
    final String truncatedTitle =
        title.length > 50 ? '${title.substring(0, 50)}...' : title;
    final String gistLink =
        'https://www.allowanceapp.org/share?type=gist&id=${widget.gistId}';
    final friendsFuture = _fetchFriends(myId);

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        Set<String> selectedFriends = {};
        bool isSending = false;
        return StatefulBuilder(
          builder: (context, setModalState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.6,
              minChildSize: 0.4,
              maxChildSize: 0.9,
              expand: false,
              builder: (_, scrollController) => Column(
                children: [
                  const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text('Share Gist',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold))),
                  ListTile(
                    leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                            color: Colors.grey[800], shape: BoxShape.circle),
                        child: const Icon(Icons.share, color: Colors.white)),
                    title: const Text('Share to other apps',
                        style: TextStyle(color: Colors.white)),
                    onTap: () {
                      Navigator.pop(ctx);
                      Share.share('$truncatedTitle\n$gistLink');
                    },
                  ),
                  const Divider(color: Colors.white10),
                  const Padding(
                      padding: EdgeInsets.all(8.0),
                      child: Text('Send to friends',
                          style:
                              TextStyle(color: Colors.white54, fontSize: 14))),
                  Expanded(
                    child: FutureBuilder<List<dynamic>>(
                        future: friendsFuture,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState ==
                              ConnectionState.waiting)
                            return Center(
                                child: CircularProgressIndicator(
                                    color: themeColor));
                          final friends = snapshot.data ?? [];
                          if (friends.isEmpty)
                            return const Center(
                                child: Text("Follow people to see them here",
                                    style: TextStyle(color: Colors.white54)));
                          return ListView.builder(
                            controller: scrollController,
                            itemCount: friends.length,
                            itemBuilder: (context, index) {
                              final friend = friends[index];
                              final isSelected =
                                  selectedFriends.contains(friend['id']);
                              return ListTile(
                                leading: CircleAvatar(
                                    backgroundImage:
                                        friend['avatar_url'] != null
                                            ? CachedNetworkImageProvider(
                                                friend['avatar_url'])
                                            : null),
                                title: Text(friend['username'] ?? 'User',
                                    style:
                                        const TextStyle(color: Colors.white)),
                                trailing: Checkbox(
                                    value: isSelected,
                                    activeColor: themeColor,
                                    onChanged: (v) => setModalState(() {
                                          v == true
                                              ? selectedFriends
                                                  .add(friend['id'])
                                              : selectedFriends
                                                  .remove(friend['id']);
                                        })),
                                onTap: () => setModalState(() {
                                  isSelected
                                      ? selectedFriends.remove(friend['id'])
                                      : selectedFriends.add(friend['id']);
                                }),
                              );
                            },
                          );
                        }),
                  ),
                  if (selectedFriends.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                              backgroundColor: themeColor,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 16)),
                          onPressed: isSending
                              ? null
                              : () async {
                                  setModalState(() => isSending = true);
                                  for (String friendId in selectedFriends) {
                                    final response = await supabase.rpc(
                                        'get_or_create_personal_chat',
                                        params: {
                                          'user_a': myId,
                                          'user_b': friendId
                                        });
                                    await supabase.from('messages').insert({
                                      'chat_id': response.toString(),
                                      'sender_id': myId,
                                      'content':
                                          'Check out this Gist: $truncatedTitle\n$gistLink',
                                      'media_url': _gist?['image_url'],
                                      'media_type':
                                          _gist?['media_type'] ?? 'image',
                                      'is_read': false,
                                    });
                                  }
                                  if (mounted) {
                                    Navigator.pop(ctx);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                            content: Text(
                                                'Sent to ${selectedFriends.length} friend(s)!'),
                                            backgroundColor: Colors.green));
                                  }
                                },
                          child: isSending
                              ? const CircularProgressIndicator(
                                  color: Colors.black)
                              : Text('Send to ${selectedFriends.length}',
                                  style: const TextStyle(
                                      color: Colors.black,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16)),
                        ),
                      ),
                    )
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildTag(String text, Color color) {
    return Container(
      margin: const EdgeInsets.only(right: 8, bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12)),
      child: Text(text,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }

  Widget _buildPollInline() {
    final String question = _gist!['title'] ?? ''; // Now we will use this!
    List<String> options = [];
    final rawOptions = _gist!['poll_options'];
    if (rawOptions != null && rawOptions is List)
      options = rawOptions.map((e) => e.toString()).toList();
    if (options.isEmpty) return const SizedBox.shrink();

    final allowMultiple = _gist!['allow_multiple_votes'] == true;
    final myId = supabase.auth.currentUser?.id;

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: supabase
          .from('poll_votes')
          .stream(primaryKey: ['id']).eq('gist_id', widget.gistId),
      builder: (context, snapshot) {
        final votes = snapshot.data ?? [];
        final myVotes = votes
            .where((v) => v['user_id'] == myId)
            .map((v) => v['option'] as String)
            .toSet();
        final totalVoters = votes.map((v) => v['user_id']).toSet().length;

        return Container(
          margin: const EdgeInsets.only(top: 16),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white10)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.poll, size: 18, color: Colors.purpleAccent),
                const SizedBox(width: 8),
                const Text('POLL',
                    style: TextStyle(
                        color: Colors.purpleAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.0)),
              ]),
              const SizedBox(height: 12),

              // 🔥 FIX: Displaying the question here!
              Text(question,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),

              ...options.map((opt) {
                final isSelected = myVotes.contains(opt);
                final optCount = votes.where((v) => v['option'] == opt).length;
                final percent =
                    votes.isEmpty ? 0 : (optCount / votes.length * 100).round();

                return GestureDetector(
                  onTap: () async {
                    if (myId == null || !_requireAuth()) return;
                    try {
                      if (isSelected) {
                        await supabase.from('poll_votes').delete().match({
                          'gist_id': widget.gistId,
                          'user_id': myId,
                          'option': opt
                        });
                      } else {
                        if (!allowMultiple && myVotes.isNotEmpty) {
                          await supabase.from('poll_votes').delete().match(
                              {'gist_id': widget.gistId, 'user_id': myId});
                        }
                        await supabase.from('poll_votes').insert({
                          'gist_id': widget.gistId,
                          'user_id': myId,
                          'option': opt
                        });
                      }
                    } catch (e) {
                      debugPrint('Vote error: $e');
                    }
                  },
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    height: 45,
                    decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(12)),
                    child: Stack(
                      children: [
                        FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: (percent / 100).clamp(0.0, 1.0),
                          child: Container(
                              decoration: BoxDecoration(
                                  color: const Color(0xFF4CAF50)
                                      .withOpacity(isSelected ? 0.8 : 0.3),
                                  borderRadius: BorderRadius.circular(12))),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            children: [
                              Icon(
                                  isSelected
                                      ? Icons.check_circle
                                      : Icons.circle_outlined,
                                  size: 20,
                                  color: Colors.white),
                              const SizedBox(width: 12),
                              Expanded(
                                  child: Text(opt,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 15,
                                          fontWeight: FontWeight.bold))),
                              Text('$percent%',
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
              const SizedBox(height: 8),
              Text(
                  '$totalVoters vote${totalVoters == 1 ? '' : 's'}${allowMultiple ? ' • Multiple answers' : ''}',
                  style: const TextStyle(color: Colors.white54, fontSize: 13)),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading)
      return const Scaffold(
          backgroundColor: Colors.black,
          body: Center(
              child: CircularProgressIndicator(color: Color(0xFF4CAF50))));
    if (_gist == null)
      return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
              backgroundColor: Colors.black,
              iconTheme: const IconThemeData(color: Colors.white)),
          body: const Center(
              child: Text("Gist not found.",
                  style: TextStyle(color: Colors.white70))));

    final imageUrl = _gist!['image_url'] ?? '';
    final imageUrls = (_gist!['image_urls'] as List?)?.cast<String>() ?? [];
    final mediaType = (_gist!['media_type'] as String?) ?? 'image';
    final gistUrl = (_gist!['url'] as String?) ?? '';
    final title = _gist!['title'] ?? '';
    final profile = _gist!['profiles'] ?? {};
    final isLocal = _gist!['type'] == 'local';
    final hasPoll = _gist!['has_poll'] == true;
    final isMoment = _gist!['is_moment'] == true;

    final imagesToShow = imageUrls.isNotEmpty
        ? imageUrls
        : (imageUrl.isNotEmpty ? [imageUrl] : []);
    final myId = supabase.auth.currentUser?.id;
    final isMe = myId == _gist!['user_id'];

    Widget mediaWidget;
    if (mediaType == 'video') {
      mediaWidget = _videoController != null &&
              _videoController!.value.isInitialized
          ? Stack(
              alignment: Alignment.center,
              children: [
                AspectRatio(
                    aspectRatio: _videoController!.value.aspectRatio,
                    child: VideoPlayer(_videoController!)),
                GestureDetector(
                  onTap: () {
                    _videoController!.value.isPlaying
                        ? _videoController!.pause()
                        : _videoController!.play();
                    setState(() {});
                  },
                  onDoubleTap: _triggerDoubleTapLike,
                  child: Container(color: Colors.transparent),
                ),
                if (!_videoController!.value.isPlaying)
                  Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.6),
                          shape: BoxShape.circle),
                      child: const Icon(Icons.play_arrow_rounded,
                          color: Colors.white, size: 54)),
                IgnorePointer(
                  child: AnimatedOpacity(
                      opacity: _showHeartOverlay ? 0.9 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: AnimatedScale(
                          scale: _showHeartOverlay ? 1.0 : 0.3,
                          duration: const Duration(milliseconds: 400),
                          curve: Curves.elasticOut,
                          child: const Icon(Icons.favorite,
                              color: Colors.white, size: 100))),
                ),
              ],
            )
          : Container(
              height: 300,
              color: Colors.black,
              child: const Center(
                  child: CircularProgressIndicator(color: Color(0xFF4CAF50))));
    } else {
      mediaWidget = imagesToShow.isEmpty
          ? Container(height: 300, color: Colors.grey[900])
          : SizedBox(
              width: double.infinity,
              height: MediaQuery.sizeOf(context).width,
              child: Stack(
                children: [
                  PageView.builder(
                    itemCount: imagesToShow.length,
                    onPageChanged: (p) => setState(() => _localPageIndex = p),
                    itemBuilder: (ctx, i) => GestureDetector(
                      onTap: () => _expandMedia(imagesToShow[i]),
                      onDoubleTap: _triggerDoubleTapLike,
                      child: CachedNetworkImage(
                          imageUrl: imagesToShow[i],
                          fit: BoxFit.cover,
                          memCacheWidth: 600),
                    ),
                  ),
                  Positioned(
                    top: 12,
                    left: 12,
                    child: GestureDetector(
                      onTap: () => _expandMedia(imagesToShow[_localPageIndex]),
                      child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: const BoxDecoration(
                              color: Colors.black54, shape: BoxShape.circle),
                          child: const Icon(Icons.fullscreen,
                              color: Colors.white, size: 20)),
                    ),
                  ),
                  if (imagesToShow.length > 1)
                    Positioned(
                      top: 12,
                      right: 12,
                      child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(20)),
                          child: Text(
                              "${_localPageIndex + 1}/${imagesToShow.length}",
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 12))),
                    ),
                  Center(
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                          opacity: _showHeartOverlay ? 0.9 : 0.0,
                          duration: const Duration(milliseconds: 200),
                          child: AnimatedScale(
                              scale: _showHeartOverlay ? 1.0 : 0.3,
                              duration: const Duration(milliseconds: 400),
                              curve: Curves.elasticOut,
                              child: const Icon(Icons.favorite,
                                  color: Colors.white, size: 100))),
                    ),
                  ),
                ],
              ),
            );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        centerTitle: true,
        title: Image.asset('assets/images/gist.png',
            height: 100, fit: BoxFit.contain),
        actions: [
          if (isMe)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: Colors.grey[900],
                    title: const Text('Delete Gist?',
                        style: TextStyle(color: Colors.white)),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel')),
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Delete',
                              style: TextStyle(color: Colors.redAccent))),
                    ],
                  ),
                );
                if (confirm == true) {
                  await supabase.from('gists').delete().eq('id', widget.gistId);
                  if (mounted) Navigator.pop(context);
                }
              },
            ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // TAGS ROW
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Wrap(
                children: [
                  if (!isMoment)
                    _buildTag(isLocal ? 'Local' : 'Global', Colors.blueAccent),
                  if (_gist!['category'] != null &&
                      _gist!['category'].toString().isNotEmpty)
                    _buildTag(_gist!['category'], Colors.orangeAccent),
                  if (hasPoll) _buildTag('Poll', Colors.purpleAccent),
                  if (isMoment) _buildTag('Moment', Colors.amber),
                ],
              ),
            ),

            mediaWidget,

            // ACTION BAR
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GestureDetector(
                    onTap: _toggleLike,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Icon(
                              _isLiked ? Icons.favorite : Icons.favorite_border,
                              color: _isLiked ? Colors.red : Colors.white,
                              size: 28),
                          const SizedBox(width: 6),
                          Text('$_likeCount',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16)),
                        ],
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () {
                      if (!_requireAuth()) return;
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text(
                              'Open this gist on your Home Feed to read comments!')));
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          const Icon(CupertinoIcons.chat_bubble,
                              color: Colors.white, size: 26),
                          const SizedBox(width: 6),
                          Text('$_commentCount',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16)),
                        ],
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => _showShipSheet(context),
                    child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Text('🚀', style: TextStyle(fontSize: 24))),
                  ),
                  GestureDetector(
                    onTap: () {
                      final target = imagesToShow.isNotEmpty
                          ? imagesToShow[_localPageIndex]
                          : imageUrl;
                      if (target.isNotEmpty) _downloadMedia(target, mediaType);
                    },
                    child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Icon(Icons.download_for_offline_outlined,
                            color: Colors.white, size: 28)),
                  ),
                ],
              ),
            ),

            // CAPTION & POLL AREA
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: Colors.grey[800],
                        backgroundImage: profile['avatar_url'] != null
                            ? CachedNetworkImageProvider(profile['avatar_url'])
                            : null,
                        child: profile['avatar_url'] == null
                            ? const Icon(Icons.person,
                                color: Colors.white, size: 20)
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: RichText(
                          text: TextSpan(
                            style: const TextStyle(
                                color: Colors.white, fontSize: 15, height: 1.4),
                            children: [
                              TextSpan(
                                  text: '${profile['username'] ?? 'User'}  ',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold)),
                              TextSpan(text: title),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),

                  // 🔥 INLINE POLL
                  if (hasPoll) _buildPollInline(),

                  if (gistUrl.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    GestureDetector(
                      onTap: () async {
                        final uri = Uri.tryParse(gistUrl);
                        if (uri != null && await canLaunchUrl(uri))
                          await launchUrl(uri,
                              mode: LaunchMode.externalApplication);
                      },
                      child: Row(
                        children: [
                          const Icon(Icons.link,
                              color: Colors.blueAccent, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                              child: Text(gistUrl,
                                  style: const TextStyle(
                                      color: Colors.blueAccent,
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold),
                                  overflow: TextOverflow.ellipsis)),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 60),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
