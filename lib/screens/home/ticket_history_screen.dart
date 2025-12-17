// lib/screens/home/ticket_history_screen.dart (updated for themed UI and grouping)
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';

class TicketHistoryScreen extends StatefulWidget {
  const TicketHistoryScreen({super.key});

  @override
  State<TicketHistoryScreen> createState() => _TicketHistoryScreenState();
}

class _TicketHistoryScreenState extends State<TicketHistoryScreen> {
  late Future<List<Map<String, dynamic>>> _historyFuture;

  @override
  void initState() {
    super.initState();
    _historyFuture = _fetchHistory();
  }

  Future<List<Map<String, dynamic>>> _fetchHistory() async {
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) return [];

    final purchases = await supabase
        .from('ticket_purchases')
        .select('*, tickets(name, date, time, organizers, location, photo_url)')
        .eq('user_id', user.id)
        .order('created_at', ascending: false);

    // Group by payment_reference
    final Map<String, Map<String, dynamic>> grouped = {};
    for (var p in purchases) {
      final ref = p['payment_reference'] as String;
      if (!grouped.containsKey(ref)) {
        grouped[ref] = {
          'reference': ref,
          'created_at': p['created_at'],
          'status': p['status'],
          'ticket': p['tickets'],
          'quantity': 0,
          'total_amount': 0.0,
        };
      }
      grouped[ref]!['quantity'] += 1;
      grouped[ref]!['total_amount'] += p['amount_paid'] as num;
    }
    return grouped.values.toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        title:
            const Text('Ticket History', style: TextStyle(color: Colors.white)),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _historyFuture,
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final history = snap.data ?? [];
          if (history.isEmpty) {
            return const Center(
                child: Text('No transaction history',
                    style: TextStyle(color: Colors.white70)));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: history.length,
            itemBuilder: (ctx, i) {
              final group = history[i];
              final ticket = group['ticket'];
              final status = group['status'] ?? 'unknown';
              final qty = group['quantity'] as int;
              final totalAmount = group['total_amount'] as double;
              return Column(
                children: [
                  _HistoryCard(
                      group: group,
                      ticket: ticket,
                      status: status,
                      qty: qty,
                      totalAmount: totalAmount),
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

class _HistoryCard extends StatelessWidget {
  final Map<String, dynamic> group;
  final Map<String, dynamic> ticket;
  final String status;
  final int qty;
  final double totalAmount;

  const _HistoryCard({
    required this.group,
    required this.ticket,
    required this.status,
    required this.qty,
    required this.totalAmount,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.grey[850],
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(children: [
            ticket['photo_url'] != null
                ? CachedNetworkImage(
                    imageUrl: ticket['photo_url'],
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
                  Text(ticket['name'] ?? 'Unknown Ticket',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Row(children: [
                    const Icon(Icons.calendar_today,
                        size: 16, color: Colors.white70),
                    const SizedBox(width: 6),
                    Text(ticket['date'] ?? '',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 14)),
                    const SizedBox(width: 16),
                    const Icon(Icons.access_time,
                        size: 16, color: Colors.white70),
                    const SizedBox(width: 6),
                    Text(ticket['time'] ?? '',
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
                    value: ticket['organizers'] ?? ''),
                const SizedBox(height: 8),
                _InfoRow(
                    icon: Icons.location_on,
                    label: 'Location',
                    value: ticket['location'] ?? ''),
                const SizedBox(height: 8),
                _InfoRow(
                    icon: Icons.confirmation_number,
                    label: 'Quantity',
                    value: qty.toString()),
                const SizedBox(height: 8),
                _InfoRow(
                    icon: Icons.attach_money,
                    label: 'Total Amount',
                    value: totalAmount.toStringAsFixed(0)),
                const SizedBox(height: 8),
                _InfoRow(
                    icon: Icons.access_time,
                    label: 'Purchased at',
                    value: group['created_at'] ?? ''),
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
                color: status == 'success' ? Colors.green : Colors.red,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Status: $status',
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    status == 'success' ? Icons.check_circle : Icons.error,
                    color: Colors.white,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
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
