// lib/screens/settings/terms_screen.dart
import 'package:flutter/material.dart';

class TermsScreen extends StatelessWidget {
  final Color themeColor;

  const TermsScreen({super.key, this.themeColor = const Color(0xFF4CAF50)});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Terms & Agreement',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.grey[850],
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white10),
          ),
          child: ListView(
            physics: const BouncingScrollPhysics(),
            children: [
              Text(
                "Allowance Terms of Service",
                style: TextStyle(
                    color: themeColor,
                    fontSize: 24,
                    fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                "Last Updated: May 2026",
                style: TextStyle(color: Colors.white54, fontSize: 12),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              _buildSectionTitle("1. Acceptance of Terms"),
              _buildParagraph(
                  "By creating an account and using Allowance (\"The Uni Cheat Code\"), you agree to be bound by these Terms of Service. If you do not agree with any part of these terms, you must not use our services."),
              _buildSectionTitle("2. Eligibility & Accounts"),
              _buildParagraph(
                  "Allowance is designed for university students in Nigeria. You must provide accurate information, including your university affiliation. You are solely responsible for maintaining the confidentiality of your account credentials. Allowance reserves the right to terminate accounts that violate our policies."),
              _buildSectionTitle(
                  "3. Marketplace, Food Orders & Delivery Runners"),
              _buildParagraph(
                  "Allowance acts strictly as a technology intermediary connecting students, campus vendors, and peer-to-peer delivery agents (Runners). \n\n"
                  "• We do not prepare, handle, or guarantee the quality, safety, or hygiene of the food provided by vendors.\n"
                  "• Delivery Agents (Runners) are independent users of the platform, not employees of Allowance. Allowance is not liable for delayed, damaged, or stolen items during transit.\n"
                  "• Any disputes regarding food quality or delivery disputes must be resolved between the user, vendor, and runner."),
              _buildSectionTitle("4. Ticketing System & Fees"),
              _buildParagraph(
                  "Users can create, buy, and transfer event tickets. \n\n"
                  "• Allowance charges a non-refundable platform fee of ₦100 per ticket sold.\n"
                  "• Allowance is not the organizer of any events listed on the platform. We are not liable for event cancellations, postponements, or misrepresentations by organizers.\n"
                  "• Refunds for canceled events are the sole responsibility of the event organizer."),
              _buildSectionTitle("5. Allowance Plus & Paid Gists"),
              _buildParagraph(
                  "• Allowance Plus is a premium subscription billed at ₦700/month via Paystack. Subscriptions are auto-renewing unless canceled. Partial month refunds are not provided.\n"
                  "• Paid Gists (Advertisements) are billed upfront based on the selected duration. Once a Gist is active and published, the payment is strictly non-refundable."),
              _buildSectionTitle("6. User-Generated Content & Conduct"),
              _buildParagraph(
                  "You are solely responsible for all content (Stories, Memories, Chat Messages, Gists) you post. \n\n"
                  "• You agree NOT to post: pornography, hate speech, harassment, fraudulent links, or illegal content.\n"
                  "• We reserve the right to review, flag, and delete any content or terminate your account without notice if you violate these rules.\n"
                  "• Private and Group chats are end-to-end encrypted where applicable, but users can report abusive behavior which may lead to bans."),
              _buildSectionTitle("7. Payments & Paystack"),
              _buildParagraph(
                  "All financial transactions are processed securely through Paystack. Allowance does not store your credit/debit card information. By making transactions on Allowance, you also agree to Paystack's Terms of Service."),
              _buildSectionTitle("8. Privacy & Data Protection (NDPR)"),
              _buildParagraph(
                  "We process your personal data (including phone numbers, school info, and optionally health data like weight/blood group) in accordance with the Nigeria Data Protection Regulation (NDPR). Your data is used solely to provide and improve the app experience."),
              _buildSectionTitle("9. Limitation of Liability"),
              _buildParagraph(
                  "To the maximum extent permitted by Nigerian law, Allowance shall not be liable for any indirect, incidental, special, or consequential damages resulting from your use or inability to use the platform. The app is provided on an \"AS IS\" basis without warranties of any kind."),
              _buildSectionTitle("10. Governing Law"),
              _buildParagraph(
                  "These terms shall be governed and construed in accordance with the laws of the Federal Republic of Nigeria. Any disputes arising shall be subject to the exclusive jurisdiction of the Nigerian courts."),
              const SizedBox(height: 30),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: themeColor,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('I Understand',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
            color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildParagraph(String text) {
    return Text(
      text,
      style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
    );
  }
}
