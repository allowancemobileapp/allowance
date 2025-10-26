// lib/screens/home/ticket_screen.dart

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// Model matching your 'tickets' table columns
class Ticket {
  final int id;
  final String name;
  final String? photoUrl;
  final DateTime date;
  final String time;
  final String organizers;
  final String location;
  final int ticketsRemaining;

  Ticket({
    required this.id,
    required this.name,
    this.photoUrl,
    required this.date,
    required this.time,
    required this.organizers,
    required this.location,
    required this.ticketsRemaining,
  });

  factory Ticket.fromMap(Map<String, dynamic> m) {
    return Ticket(
      id: m['id'] as int,
      name: m['name'] as String,
      photoUrl: m['photo_url'] as String?,
      date: DateTime.parse(m['date'] as String),
      time: m['time'] as String,
      organizers: m['organizers'] as String,
      location: m['location'] as String,
      ticketsRemaining: m['tickets_remaining'] as int,
    );
  }
}

class TicketScreen extends StatefulWidget {
  const TicketScreen({super.key});

  @override
  State<TicketScreen> createState() => _TicketScreenState();
}

class _TicketScreenState extends State<TicketScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final Color themeColor = const Color(0xFF4CAF50);

  List<Ticket> _tickets = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadTickets();
  }

  Future<void> _loadTickets() async {
    try {
      final response = await _supabase
          .from('tickets')
          .select(
            'id, name, photo_url, date, time, organizers, location, tickets_remaining',
          )
          .order('date', ascending: true);

      final rows = response as List;
      setState(() {
        _tickets =
            rows.map((r) => Ticket.fromMap(r as Map<String, dynamic>)).toList();
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load tickets: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        centerTitle: true,
        leading: const BackButton(color: Colors.white),
        title: Image.asset('assets/images/tickets.png', height: 110),
        actions: const [SizedBox(width: kToolbarHeight)],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child:
                      Text(_error!, style: const TextStyle(color: Colors.red)))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _tickets.length,
                  itemBuilder: (ctx, idx) {
                    final t = _tickets[idx];
                    return Column(
                      children: [
                        _TicketCard(event: t, themeColor: themeColor),
                        const SizedBox(height: 24),
                      ],
                    );
                  },
                ),
    );
  }
}

class _TicketCard extends StatelessWidget {
  final Ticket event;
  final Color themeColor;

  const _TicketCard({
    required this.event,
    required this.themeColor,
  });

  String get formattedDate {
    // e.g. Fri, 24 Feb 2023
    final w = [
      'Mon',
      'Tue',
      'Wed',
      'Thu',
      'Fri',
      'Sat',
      'Sun'
    ][event.date.weekday - 1];
    final m = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ][event.date.month - 1];
    return '$w, ${event.date.day} $m ${event.date.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(children: [
            event.photoUrl != null
                ? CachedNetworkImage(
                    imageUrl: event.photoUrl!,
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
                  Text(event.name,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Row(children: [
                    const Icon(Icons.calendar_today,
                        size: 16, color: Colors.white70),
                    const SizedBox(width: 6),
                    Text(formattedDate,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 14)),
                    const SizedBox(width: 16),
                    const Icon(Icons.access_time,
                        size: 16, color: Colors.white70),
                    const SizedBox(width: 6),
                    Text(event.time,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 14)),
                  ]),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(children: [
              _InfoRow(
                  icon: Icons.person,
                  label: 'Organizers',
                  value: event.organizers),
              const SizedBox(height: 8),
              _InfoRow(
                  icon: Icons.location_on,
                  label: 'Location',
                  value: event.location),
              const SizedBox(height: 8),
              _InfoRow(
                  icon: Icons.confirmation_number,
                  label: 'Tickets remaining',
                  value: '${event.ticketsRemaining}'),
            ]),
          ),
          const SizedBox(height: 24),
          LayoutBuilder(builder: (ctx, box) {
            final count = (box.maxWidth / 12).floor();
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(count, (_) {
                return SizedBox(
                    width: 6,
                    height: 2,
                    child: DecoratedBox(
                        decoration: BoxDecoration(color: Colors.grey[400])));
              }),
            );
          }),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: () {/* TODO: Buy logic */},
                icon: const Icon(Icons.shopping_cart, size: 20),
                label: const Text('Buy Ticket',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(
                    backgroundColor: themeColor,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))),
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
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, color: Colors.grey[700], size: 20),
      const SizedBox(width: 8),
      Expanded(
          child: RichText(
        text: TextSpan(
          text: '$label: ',
          style: TextStyle(
              color: Colors.grey[500],
              fontWeight: FontWeight.w600,
              fontSize: 12),
          children: [
            TextSpan(
                text: value,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13))
          ],
        ),
      )),
    ]);
  }
}
