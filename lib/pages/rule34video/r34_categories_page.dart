import 'package:flutter/material.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/def.dart';
import 'package:pica_comic/foundation/image_loader/cached_image.dart';
import 'package:pica_comic/network/rule34video/models.dart';
import 'package:pica_comic/network/rule34video/rule34video_network.dart';
import 'package:pica_comic/pages/category_comics_page.dart';
import 'package:pica_comic/tools/translations.dart';

/// Every category of rule34video, the ones with the most videos first,
/// loaded page by page as the list is scrolled.
class R34CategoriesPage extends StatefulWidget {
  const R34CategoriesPage({super.key});

  @override
  State<R34CategoriesPage> createState() => _R34CategoriesPageState();
}

class _R34CategoriesPageState extends State<R34CategoriesPage> {
  final categories = <R34Category>[];
  int loadedPages = 0;
  int? lastPage;
  bool loading = false;
  String? error;

  bool get hasMore => lastPage == null || loadedPages < lastPage!;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (loading || !hasMore) return;
    setState(() {
      loading = true;
      error = null;
    });
    var res = await Rule34VideoNetwork().getCategories(loadedPages + 1);
    if (!mounted) return;
    setState(() {
      loading = false;
      if (res.error) {
        error = res.errorMessage;
      } else {
        loadedPages++;
        lastPage = res.subData as int?;
        var known = categories.map((c) => c.path).toSet();
        categories.addAll(res.data.where((c) => known.add(c.path)));
        if (res.data.isEmpty) lastPage = loadedPages;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text('所有分类'.tl)),
      body: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.extentAfter < 600) _loadMore();
          return false;
        },
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(8),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 200,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 0.85,
                ),
                delegate: SliverChildBuilderDelegate(
                  childCount: categories.length,
                  (context, i) => _CategoryTile(categories[i]),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: error != null
                      ? Column(
                          children: [
                            Text(error!, textAlign: TextAlign.center),
                            const SizedBox(height: 8),
                            FilledButton.tonal(
                              onPressed: _loadMore,
                              child: Text('重试'.tl),
                            ),
                          ],
                        )
                      : loading
                          ? const CircularProgressIndicator()
                          : const SizedBox(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile(this.category);

  final R34Category category;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.to(() => CategoryComicsPage(
              category: category.name,
              categoryKey: rule34videoKey,
              param: category.path,
            )),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: category.image.isEmpty
                  ? const SizedBox()
                  : Image(
                      image: CachedImageProvider(category.image,
                          headers: const {'User-Agent': webUA}),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox(),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                category.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
