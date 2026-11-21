import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

class TrackerFilterService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Stream<List<Map<String, dynamic>>> obtenerReglasActivas(
    String childId,
    Set<String> categories,
  ) {
    final validCategories = categories
        .where((category) => category == 'app' || category == 'url')
        .toSet();

    if (validCategories.isEmpty) {
      return Stream.value([]);
    }

    return Stream<List<Map<String, dynamic>>>.multi((controller) {
      final latestByCategory = <String, List<Map<String, dynamic>>>{};
      final subscriptions =
          <StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>[];

      for (final category in validCategories) {
        final subscription = _firestore
            .collection('children')
            .doc(childId)
            .collection('filter_rules')
            .where('category', isEqualTo: category)
            .where('isEnabled', isEqualTo: true)
            .snapshots()
            .listen(
          (snapshot) {
            latestByCategory[category] = snapshot.docs.map((doc) {
              final data = doc.data();
              return {
                'id': doc.id,
                'value': data['value'] ?? '',
                'type': data['type'] ?? 'block',
                'category': data['category'] ?? category,
              };
            }).toList();

            controller.add(
              latestByCategory.values.expand((rules) => rules).toList(),
            );
          },
          onError: (Object error, StackTrace stackTrace) {
            controller.addError(error, stackTrace);
          },
        );

        subscriptions.add(subscription);
      }

      controller.onCancel = () async {
        await Future.wait(subscriptions.map((subscription) {
          return subscription.cancel();
        }));
      };
    });
  }

  bool evaluarUrl(String urlActual, List<Map<String, dynamic>> reglas) {
    for (final regla in reglas) {
      if (regla['type'] == 'block') {
        final valorBloqueado = regla['value'].toString().toLowerCase();
        if (urlActual.toLowerCase().contains(valorBloqueado)) {
          return true;
        }
      }
    }
    return false;
  }
}
