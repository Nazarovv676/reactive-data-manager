import 'package:flutter/material.dart';
import 'package:reactive_data_manager/reactive_data_manager.dart';

void main() {
  runApp(const MyApp());
}

// Sample data class
class User {
  final int id;
  final String name;
  final int age;

  User({required this.id, required this.name, required this.age});

  User copyWith({String? name, int? age}) {
    return User(
      id: id,
      name: name ?? this.name,
      age: age ?? this.age,
    );
  }

  @override
  String toString() => 'User(id: $id, name: $name, age: $age)';
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const ReactiveShowcase(),
    );
  }
}

class ReactiveShowcase extends StatefulWidget {
  const ReactiveShowcase({super.key});

  @override
  State<ReactiveShowcase> createState() => _ReactiveShowcaseState();
}

class _ReactiveShowcaseState extends State<ReactiveShowcase> {
  late final ReactiveDataManager<int, User> _userManager;
  final _nameController = TextEditingController();
  final List<int> userIds = List.generate(100, (id) => id);

  @override
  void initState() {
    super.initState();
    _userManager = ReactiveDataManager<int, User>(
      fetcher: _fetchUser,
      updater: _updateUser,
    );

    // Prefetch all users
    for (final id in userIds) {
      _userManager.getData(id);
    }
  }

  Future<User> _fetchUser(int id) async {
    await Future.delayed(const Duration(seconds: 1));
    return User(
      id: id,
      name: 'User $id',
      age: 20 + id,
    );
  }

  Future<User> _updateUser(int id, User user) async {
    await Future.delayed(const Duration(milliseconds: 500));
    return user;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _userManager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Example')),
      body: ListView.builder(
        itemCount: userIds.length,
        itemBuilder: (context, index) {
          final userId = userIds[index];
          return Card(
            margin: const EdgeInsets.all(8),
            child: StreamBuilder<User?>(
              stream: _userManager.getStream(userId),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return ListTile(
                    title: Text('Error: ${snapshot.error}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.refresh),
                      onPressed: () =>
                          _userManager.getData(userId, forceRefresh: true),
                    ),
                  );
                }

                if (!snapshot.hasData) {
                  return const ListTile(
                    title: Center(child: CircularProgressIndicator()),
                  );
                }

                final user = snapshot.data!;
                return ListTile(
                  title: Text('Name: ${user.name}'),
                  subtitle: Text('Age: ${user.age}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit),
                        onPressed: () => _showEditDialog(user),
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh),
                        onPressed: () =>
                            _userManager.getData(userId, forceRefresh: true),
                      ),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Future<void> _showEditDialog(User user) async {
    _nameController.text = user.name;
    return showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Edit User ${user.id}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final updatedUser = user.copyWith(name: _nameController.text);
              _userManager.updateData(user.id, updatedUser);
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
