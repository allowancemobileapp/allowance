// lib/screens/home/my_tickets_screen.dart (updated for themed UI, countdown, and buy more)
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:async';
import '../../shared/services/ticket_service.dart'; // For purchaseTickets
import 'package:http/http.dart' as http; // For Paystack if needed, but stubbed
import 'package:flutter_dotenv/flutter_dotenv.dart'; // For keys
import 'package:url_launcher/url_launcher.dart'; // For launchUrl

class MyTicketsScreen extends StatefulWidget {
  const MyTicketsScreen({super.key});

  @override
  State<MyTicketsScreen> createState() => _MyTicketsScreenState();
}

class _MyTicketsScreenState extends State<MyTicketsScreen> {
  late Future<List<dynamic>> _myTicketsFuture;

  @override
  void initState() {
    super.initState();
    _myTicketsFuture = _fetchMyTickets();
  }

  Future<List<dynamic>> _fetchMyTickets() async {
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) return [];

    final purchases = await supabase
        .from('ticket_purchases')
        .select('ticket_id')
        .eq('user_id', user.id)
        .eq('status', 'success');

    final Map<int, int> counts = {};
    for (var p in purchases) {
      final id = p['ticket_id'] as int;
      counts[id] = (counts[id] ?? 0) + 1;
    }

    final ticketIds = counts.keys.toList();
    if (ticketIds.isEmpty) return [];

    final tickets = await supabase
        .from('tickets')
        .select(
            '*') // Fetch all fields including photo_url, organizers, location, etc.
        .inFilter('id', ticketIds);

    return tickets.map((t) {
      final qty = counts[t['id']] ?? 1;
      t['owned_quantity'] = qty;
      return t;
    }).toList();
  }

  Future<int?> _showQuantityDialog(int maxAvailable) async {
    int qty = 1;
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title:
            const Text('How many more?', style: TextStyle(color: Colors.white)),
        content: StatefulBuilder(
          builder: (ctx, setState) => Slider(
            value: qty.toDouble(),
            min: 1,
            max: maxAvailable.clamp(1, 10).toDouble(),
            divisions: maxAvailable.clamp(1, 10) - 1,
            label: qty.toString(),
            activeColor: Colors.amber,
            onChanged: (v) => setState(() => qty = v.round()),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel',
                  style: TextStyle(color: Colors.white70))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, qty),
              child: const Text('OK', style: TextStyle(color: Colors.amber))),
        ],
      ),
    );
  }

  void _showTicketOptions(Map<String, dynamic> ticket) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[850],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.share, color: Colors.white70),
            title: const Text('Share', style: TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(ctx);
              _showTransferDialog(ticket);
            },
          ),
          ListTile(
            leading: const Icon(Icons.add, color: Colors.white70),
            title:
                const Text('Buy More', style: TextStyle(color: Colors.white)),
            onTap: () async {
              Navigator.pop(ctx);
              final supabase = Supabase.instance.client;
              final ticketData = await supabase
                  .from('tickets')
                  .select('tickets_remaining, price')
                  .eq('id', ticket['id'])
                  .single();
              final maxAvailable = ticketData['tickets_remaining'] as int;
              if (maxAvailable <= 0) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Sold out!')));
                return;
              }
              final qty = await _showQuantityDialog(maxAvailable);
              if (qty == null || qty <= 0) return;

              // Stub payment - in full app, integrate Paystack here like in ticket_screen.dart
              // For now, assume success and call service
              final reference =
                  'buymore_${ticket['id']}_${DateTime.now().millisecondsSinceEpoch}';
              await TicketService.instance.purchaseTickets(
                ticketId: ticket['id'],
                quantity: qty,
                paymentReference: reference,
                amountPaid: (ticketData['price'] as num) * qty,
              );
              setState(() => _myTicketsFuture = _fetchMyTickets());
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Purchased more tickets!')));
            },
          ),
        ],
      ),
    );
  }

  void _showTransferDialog(Map<String, dynamic> ticket) {
    final qtyController = TextEditingController();
    final usernameController = TextEditingController();
    final maxQty = ticket['owned_quantity'] as int;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[850],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: usernameController,
              decoration: const InputDecoration(
                labelText: 'Recipient Username',
                labelStyle: TextStyle(color: Colors.white70),
                enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white70)),
              ),
              style: const TextStyle(color: Colors.white),
            ),
            TextField(
              controller: qtyController,
              decoration: InputDecoration(
                labelText: 'Number of Tickets (max $maxQty)',
                labelStyle: const TextStyle(color: Colors.white70),
                enabledBorder: const UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white70)),
              ),
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () async {
                final qty = int.tryParse(qtyController.text) ?? 0;
                if (qty <= 0 || qty > maxQty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Invalid quantity')));
                  return;
                }
                final username = usernameController.text.trim();
                if (username.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Enter username')));
                  return;
                }

                try {
                  await _transferTickets(ticket['id'], qty, username);
                  Navigator.pop(ctx);
                  setState(() => _myTicketsFuture = _fetchMyTickets());
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Tickets transferred!')));
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Transfer failed: $e')));
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.amber),
              child: const Text('Share', style: TextStyle(color: Colors.black)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _transferTickets(
      int ticketId, int quantity, String recipientUsername) async {
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) throw Exception('Not authenticated');

    final recipient = await supabase
        .from('profiles')
        .select('id')
        .eq('username', recipientUsername)
        .maybeSingle();

    if (recipient == null) throw Exception('User not found');

    final recipientId = recipient['id'] as String;

    await supabase
        .from('ticket_purchases')
        .update({'user_id': recipientId}).match({
      'ticket_id': ticketId,
      'user_id': user.id,
    }).limit(quantity);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        title: const Text('My Tickets', style: TextStyle(color: Colors.white)),
      ),
      body: FutureBuilder<List<dynamic>>(
        future: _myTicketsFuture,
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final tickets = snap.data ?? [];
          if (tickets.isEmpty) {
            return const Center(
                child: Text('No tickets owned',
                    style: TextStyle(color: Colors.white70)));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: tickets.length,
            itemBuilder: (ctx, i) {
              final ticket = tickets[i];
              return Column(
                children: [
                  _OwnedTicketCard(
                      ticket: ticket, onTap: () => _showTicketOptions(ticket)),
                  const SizedBox(height: 24),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _OwnedTicketCard extends StatefulWidget {
  final Map<String, dynamic> ticket;
  final VoidCallback onTap;

  const _OwnedTicketCard({required this.ticket, required this.onTap});

  @override
  _OwnedTicketCardState createState() => _OwnedTicketCardState();
}

class _OwnedTicketCardState extends State<_OwnedTicketCard> {
  late Timer _timer;
  Duration _remaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    _calculateRemaining();
    _timer = Timer.periodic(
        const Duration(seconds: 1), (_) => _calculateRemaining());
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  void _calculateRemaining() {
    final dt = DateTime.parse(widget.ticket['date'].toString());
    final timeParts = (widget.ticket['time'] as String).split(':');
    final eventDateTime = DateTime(
      dt.year,
      dt.month,
      dt.day,
      int.tryParse(timeParts[0]) ?? 0,
      int.tryParse(timeParts[1]) ?? 0,
    );
    final diff = eventDateTime.difference(DateTime.now());
    if (mounted) setState(() => _remaining = diff);
  }

  String get countdownText {
    if (_remaining.isNegative) return 'Event Ended';
    final days = _remaining.inDays;
    final hours = _remaining.inHours % 24;
    final minutes = _remaining.inMinutes % 60;
    if (days > 0) return '$days day${days > 1 ? 's' : ''} left';
    if (hours > 0) return '$hours hr${hours > 1 ? 's' : ''} left';
    return '$minutes min left';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: Card(
        color: Colors.grey[850],
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        clipBehavior: Clip.hardEdge,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Stack(children: [
              widget.ticket['photo_url'] != null
                  ? CachedNetworkImage(
                      imageUrl: widget.ticket['photo_url'],
                      height: 200,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      placeholder: (_, __) =>
                          Container(height: 200, color: Colors.grey[700]),
                      errorWidget: (_, __, ___) => Container(
                        height: 200,
                        color: Colors.grey[300],
                        alignment: Alignment.center,
                        child: const Icon(Icons.broken_image, size: 60),
                      ),
                    )
                  : Container(
                      height: 200,
                      color: Colors.grey[300],
                      alignment: Alignment.center,
                      child: const Icon(Icons.image_not_supported, size: 60),
                    ),
              Container(
                height: 200,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black54, Colors.transparent],
                  ),
                ),
              ),
              Positioned(
                bottom: 16,
                left: 16,
                right: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.ticket['name'] ?? 'Untitled',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Row(children: [
                      const Icon(Icons.calendar_today,
                          size: 16, color: Colors.white70),
                      const SizedBox(width: 6),
                      Text(widget.ticket['date'] ?? '',
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 14)),
                      const SizedBox(width: 16),
                      const Icon(Icons.access_time,
                          size: 16, color: Colors.white70),
                      const SizedBox(width: 6),
                      Text(widget.ticket['time'] ?? '',
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 14)),
                    ]),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  _InfoRow(
                      icon: Icons.person,
                      label: 'Organizers',
                      value: widget.ticket['organizers'] ?? ''),
                  const SizedBox(height: 8),
                  _InfoRow(
                      icon: Icons.location_on,
                      label: 'Location',
                      value: widget.ticket['location'] ?? ''),
                  const SizedBox(height: 8),
                  _InfoRow(
                      icon: Icons.timer,
                      label: 'Time to event',
                      value: countdownText),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Divider(
                color: Colors.grey[700],
                thickness: 0.5,
                indent: 24,
                endIndent: 24),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Container(
                width: double.infinity,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.amber,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${widget.ticket['owned_quantity']} ticket${widget.ticket['owned_quantity'] > 1 ? 's' : ''}',
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.black),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoRow(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, color: Colors.white70, size: 20),
      const SizedBox(width: 8),
      Expanded(
        child: RichText(
          text: TextSpan(
            text: '$label: ',
            style: const TextStyle(
                color: Colors.white70,
                fontWeight: FontWeight.w600,
                fontSize: 12),
            children: [
              TextSpan(
                text: value,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    ]);
  }
}
