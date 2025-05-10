import 'dart:async';
import 'dart:math';

import 'package:location/location.dart' as loc;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geocoding/geocoding.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:bite_nearby/services/Restaurant_service.dart';

class NotificationTemplate {
  final String id;
  final String title;
  final String body;
  final String type;

  NotificationTemplate({
    required this.id,
    required this.title,
    required this.body,
    required this.type,
  });

  factory NotificationTemplate.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return NotificationTemplate(
      id: doc.id,
      title: data['title'] ?? 'Nearby Restaurant',
      body: data['body'] ?? 'Check out this place!',
      type: data['type'] ?? 'recommendation',
    );
  }
}

class LocationService {
  final loc.Location _location = loc.Location();
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  bool _isMonitoring = false;
  Timer? _monitoringTimer;

  static const AndroidNotificationDetails _androidNotificationDetails =
      AndroidNotificationDetails(
    'proximity_channel', // Consistent channel ID
    'Proximity Alerts',
    importance: Importance.high,
    priority: Priority.high,
    enableVibration: true,
    playSound: true,
  );

  static const NotificationDetails _platformChannelSpecifics =
      NotificationDetails(android: _androidNotificationDetails);

  Future<Map<String, dynamic>> getCurrentLocation() async {
    try {
      bool serviceEnabled = await _location.serviceEnabled();
      if (!serviceEnabled) {
        serviceEnabled = await _location.requestService();
        if (!serviceEnabled) {
          throw Exception("Location services are disabled.");
        }
      }

      loc.PermissionStatus permissionGranted = await _location.hasPermission();
      if (permissionGranted == loc.PermissionStatus.denied) {
        permissionGranted = await _location.requestPermission();
        if (permissionGranted != loc.PermissionStatus.granted) {
          throw Exception("Location permission denied.");
        }
      }

      final locationData = await _location.getLocation();
      final latitude = locationData.latitude ?? 0.0;
      final longitude = locationData.longitude ?? 0.0;

      final address = await getAddressFromCoordinates(latitude, longitude);
      print("Fetched User Location: $address");

      return {
        'geoPoint': GeoPoint(latitude, longitude),
        'address': address,
      };
    } catch (e) {
      print("Error getting location: $e");
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> getPopularItems(
      String restaurantId) async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('Restaurants')
          .doc(restaurantId)
          .collection('menu')
          .orderBy('rating', descending: true)
          .limit(3)
          .get();

      return snapshot.docs.map((doc) => doc.data()).toList();
    } catch (e) {
      print('Error fetching menu items: $e');
      return [];
    }
  }

  Future<NotificationTemplate?> getRandomNotificationTemplate() async {
    try {
      print("Fetching notification templates...");
      final querySnapshot = await FirebaseFirestore.instance
          .collection('notification_templates')
          .get();

      print("Found ${querySnapshot.docs.length} templates");

      if (querySnapshot.docs.isEmpty) {
        print("No templates found in Firestore");
        return null;
      }

      final randomIndex = Random().nextInt(querySnapshot.docs.length);
      final selectedTemplate = querySnapshot.docs[randomIndex];
      print("Selected template ID: ${selectedTemplate.id}");

      return NotificationTemplate.fromFirestore(selectedTemplate);
    } catch (e) {
      print("Error fetching templates: $e");
      return null;
    }
  }

  Future<void> startProximityMonitoring() async {
    if (_isMonitoring) return;
    _isMonitoring = true;

    const interval = Duration(minutes: 1);
    _monitoringTimer = Timer.periodic(interval, (timer) async {
      try {
        print("Checking proximity...");
        final locationData = await getCurrentLocation();
        final restaurants = await RestaurantService().getSortedRestaurants();

        if (restaurants.isNotEmpty) {
          final nearest = restaurants.first;
          final distanceKm = nearest['distance'] / 1000;
          print("Nearest restaurant: ${nearest['name']} ($distanceKm km away)");

          if (distanceKm <= 15) {
            print("Restaurant within range - showing notification");
            await showDynamicNotification(nearest);
          }
        }
      } catch (e) {
        print('Proximity monitoring error: $e');
      }
    });
  }

  Future<void> showDynamicNotification(Map<String, dynamic> restaurant) async {
    try {
      print("Preparing dynamic notification...");
      final template = await getRandomNotificationTemplate();
      final popularItems = await getPopularItems(restaurant['id']);
      final topItem = popularItems.isNotEmpty
          ? popularItems.first['Name'] ?? 'delicious food'
          : 'delicious food';

      print("Template: ${template?.title}");
      print("Top item: $topItem");

      final title = template?.title
              ?.replaceAll('{restaurant_name}', restaurant['name'])
              ?.replaceAll('{item_name}', topItem) ??
          'Nearby Restaurant: ${restaurant['name']}';

      final body = template?.body
              ?.replaceAll('{item_name}', topItem)
              ?.replaceAll('{restaurant_name}', restaurant['name']) ??
          'You\'re close to ${restaurant['name']}. Try their $topItem!';

      print("Notification content:");
      print("Title: $title");
      print("Body: $body");

      await _notificationsPlugin.show(
        restaurant['id'].hashCode,
        title,
        body,
        _platformChannelSpecifics,
        payload: 'restaurant:${restaurant['id']}',
      );
    } catch (e) {
      print('Notification error: $e');
      // Fallback notification
      await _notificationsPlugin.show(
        restaurant['id'].hashCode,
        'Nearby Restaurant: ${restaurant['name']}',
        'Check out ${restaurant['name']}!',
        _platformChannelSpecifics,
      );
    }
  }

  Future<String> getAddressFromCoordinates(double lat, double lng) async {
    try {
      final placemarks = await placemarkFromCoordinates(lat, lng);
      if (placemarks.isNotEmpty) {
        final place = placemarks[0];
        return "${place.street}, ${place.locality}, ${place.country}";
      }
      return "Unknown location";
    } catch (e) {
      print("Error fetching address: $e");
      return "Unknown location";
    }
  }

  void stopProximityMonitoring() {
    _monitoringTimer?.cancel();
    _monitoringTimer = null;
    _isMonitoring = false;
    print("Proximity monitoring stopped");
  }

  void dispose() {
    stopProximityMonitoring();
    print("LocationService disposed");
  }
}
