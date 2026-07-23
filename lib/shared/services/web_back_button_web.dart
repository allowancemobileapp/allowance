import 'dart:html' as html;
import 'package:flutter/material.dart';

void initWebBackButton(GlobalKey<NavigatorState> navigatorKey) {
  html.window.onPopState.listen((event) {
    if (navigatorKey.currentState?.canPop() == true) {
      navigatorKey.currentState?.pop();
      event.preventDefault();
    }
  });
}
