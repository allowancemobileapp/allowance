// lib/screens/home/ticket_screen.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;

class Ticket {
  final int id;
  final String name;
  final String? photoUrl;
  final DateTime date;
  final String time;
  final String organizers;
  final String location;
  final int ticketsRemaining;
  final double price;
  final bool paid;
  final String status;
  Ticket({
    required this.id,
    required this.name,
    this.photoUrl,
    required this.date,
    required this.time,
    required this.organizers,
    required this.location,
    required this.ticketsRemaining,
    required this.price,
    required this.paid,
    required this.status,
  });
  factory Ticket.fromMap(Map<String, dynamic> m) {
    return Ticket(
      id: m['id'] as int,
      name: m['name'] ?? 'Untitled Event',
      photoUrl: m['photo_url'] as String?,
      date: DateTime.parse(m['date'].toString()),
      time: m['time'] ?? '00:00',
      organizers: m['organizers'] ?? 'Unknown',
      location: m['location'] ?? 'Unknown',
      ticketsRemaining: m['tickets_remaining'] ?? 0,
      price: (m['price'] != null)
          ? double.tryParse(m['price'].toString()) ?? 0.0
          : 0.0,
      paid: m['paid'] ?? false,
      status: m['status'] ?? 'active',
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
              'id, name, photo_url, date, time, organizers, location, tickets_remaining, price, paid, status')
          .eq('status', 'active')
          .order('date', ascending: true);
      final rows = response as List;
      setState(() {
        _tickets = rows.map((r) => Ticket.fromMap(r)).toList();
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error =
            'Sorry, we couldn\'t load the tickets right now. Please try again later.';
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
              : RefreshIndicator(
                  color: themeColor,
                  onRefresh: _loadTickets,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _tickets.length,
                    itemBuilder: (ctx, idx) {
                      final t = _tickets[idx];
                      return Column(
                        children: [
                          _TicketCard(
                              event: t,
                              themeColor: themeColor,
                              onPurchaseSuccess: _loadTickets),
                          const SizedBox(height: 24),
                        ],
                      );
                    },
                  ),
                ),
    );
  }
}

class _TicketCard extends StatefulWidget {
  final Ticket event;
  final Color themeColor;
  final VoidCallback onPurchaseSuccess;
  const _TicketCard({
    required this.event,
    required this.themeColor,
    required this.onPurchaseSuccess,
  });
  @override
  State<_TicketCard> createState() => _TicketCardState();
}

class _TicketCardState extends State<_TicketCard> {
  late Timer _timer;
  Duration _remaining = Duration.zero;
  bool _isProcessing = false;
  @override
  void initState() {
    super.initState();
    _calculateRemaining();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _calculateRemaining();
    });
  }

  void _calculateRemaining() {
    final dt = widget.event.date;
    final timeParts = widget.event.time.split(':');
    DateTime eventDateTime = DateTime(
      dt.year,
      dt.month,
      dt.day,
      int.tryParse(timeParts[0]) ?? 0,
      int.tryParse(timeParts[1]) ?? 0,
    );
    final diff = eventDateTime.difference(DateTime.now());
    if (mounted) setState(() => _remaining = diff);
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  String get formattedDate {
    final df = DateFormat('EEE, dd MMM yyyy');
    return df.format(widget.event.date);
  }

  String get countdownText {
    if (_remaining.isNegative) return 'Event Ended';
    final days = _remaining.inDays;
    final hours = _remaining.inHours % 24;
    final minutes = _remaining.inMinutes % 60;
    if (days > 0) {
      return '$days day${days > 1 ? 's' : ''} left';
    } else if (hours > 0) {
      return '$hours hr${hours > 1 ? 's' : ''} left';
    } else {
      return '$minutes min left';
    }
  }

  Future<void> _buyTicket() async {
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please log in to buy tickets.')),
      );
      return;
    }
    if (widget.event.ticketsRemaining <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This event is sold out.')),
      );
      return;
    }
    final priceNaira = widget.event.price.toInt();
    if (priceNaira <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Sorry, there\'s an issue with the ticket price. Please try again later.')),
      );
      return;
    }
    setState(() => _isProcessing = true);
    final paystackSecretKey = dotenv.env['PAYSTACK_SECRET_KEY'];
    if (paystackSecretKey == null || paystackSecretKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Sorry, the payment system is unavailable right now. Please try again later.')),
      );
      setState(() => _isProcessing = false);
      return;
    }
    try {
      final reference =
          'ticket_${widget.event.id}_${DateTime.now().millisecondsSinceEpoch}';
      final payload = {
        'amount': priceNaira * 100, // amount in kobo
        'email': user.email ?? '',
        'reference': reference,
        'metadata': {'ticket_id': widget.event.id, 'user_id': user.id}
      };
      final httpResp = await http.post(
        Uri.parse('https://api.paystack.co/transaction/initialize'),
        headers: {
          'Authorization': 'Bearer $paystackSecretKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(payload),
      );
      if (httpResp.statusCode != 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Sorry, we couldn\'t start the payment process. Please try again.')),
        );
        setState(() => _isProcessing = false);
        return;
      }
      final body = jsonDecode(httpResp.body) as Map<String, dynamic>;
      final authUrl = body['data']?['authorization_url'];
      if (authUrl == null)
        throw 'Sorry, payment setup failed. Please try again.';
      final uri = Uri.parse(authUrl);
      bool launched =
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) {
        launched = await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
      if (!launched)
        throw 'Unable to open the payment page. Please check your browser settings.';
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Payment page opened — verify after payment')),
      );
      await _promptVerify(reference, widget.event.id, priceNaira);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Payment error: $e')),
      );
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _promptVerify(String reference, int ticketId, int amount) async {
    final shouldVerify = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Complete Payment',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'After completing payment in your browser, tap Verify to confirm your ticket purchase.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Verify')),
        ],
      ),
    );
    if (shouldVerify == true) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
      final ok = await _verifyPayment(reference, ticketId, amount);
      if (mounted) Navigator.pop(context);
      if (ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Payment verified — ticket purchased!')),
        );
        widget.onPurchaseSuccess();
      }
    }
  }

  Future<bool> _verifyPayment(
      String reference, int ticketId, int amount) async {
    final paystackSecretKey = dotenv.env['PAYSTACK_SECRET_KEY'];
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser!;
    try {
      final verifyUrl =
          Uri.parse('https://api.paystack.co/transaction/verify/$reference');
      final resp = await http.get(
        verifyUrl,
        headers: {
          'Authorization': 'Bearer $paystackSecretKey',
          'Content-Type': 'application/json',
        },
      );
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (resp.statusCode != 200 || data['data']?['status'] != 'success') {
        return false;
      }
      await supabase.from('ticket_purchases').insert({
        'user_id': user.id,
        'ticket_id': ticketId,
        'payment_reference': reference,
        'amount_paid': amount * 100,
      });
      await supabase
          .from('tickets')
          .update({'tickets_remaining': widget.event.ticketsRemaining - 1}).eq(
              'id', ticketId);
      return true;
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Sorry, we couldn\'t verify your payment. Please try again.')),
      );
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSoldOut = widget.event.ticketsRemaining <= 0;
    final isEnded = _remaining.isNegative;
    return Card(
      color: Colors.grey[850],
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(children: [
            widget.event.photoUrl != null
                ? CachedNetworkImage(
                    imageUrl: widget.event.photoUrl!,
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
                  Text(widget.event.name,
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
                    Text(widget.event.time,
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
                    value: widget.event.organizers),
                const SizedBox(height: 8),
                _InfoRow(
                    icon: Icons.location_on,
                    label: 'Location',
                    value: widget.event.location),
                const SizedBox(height: 8),
                _InfoRow(
                    icon: Icons.confirmation_number,
                    label: 'Tickets remaining',
                    value: '${widget.event.ticketsRemaining}'),
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
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed:
                    (isEnded || isSoldOut || _isProcessing) ? null : _buyTicket,
                style: ElevatedButton.styleFrom(
                  backgroundColor: isSoldOut || isEnded
                      ? Colors.grey[600]
                      : widget.themeColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isProcessing
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Text(
                        isEnded
                            ? 'Event Ended'
                            : isSoldOut
                                ? 'SOLD OUT'
                                : 'Buy for ₦${widget.event.price.toStringAsFixed(0)}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
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
      Icon(icon, color: Colors.white70, size: 20),
      const SizedBox(width: 8),
      Expanded(
        child: RichText(
          text: TextSpan(
            text: '$label: ',
            style: const TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
            children: [
              TextSpan(
                text: value,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    ]);
  }
}
