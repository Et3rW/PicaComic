import 'package:flutter/material.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/page_translation/translation_tasks.dart';
import 'package:pica_comic/tools/translations.dart';

/// Which tasks the page shows.
enum _Filter {
  all('全部', '没有翻译任务。在阅读器里点翻译按钮后, 本章会在后台翻译, 退出漫画也会继续。'),
  active('进行中', '没有进行中的任务'),
  succeeded('成功', '没有成功的任务'),
  failed('失败', '没有失败的任务');

  const _Filter(this.label, this.empty);

  final String label;

  /// Shown when no task is in the filter.
  final String empty;

  bool matches(TranslationTask task) => switch (this) {
        all => true,
        active => task.isActive,
        succeeded => task.isSucceeded,
        failed => task.isFailed,
      };
}

/// The chapters being translated in the background, and how the last ones
/// went.
class TranslationTasksPage extends StatefulWidget {
  const TranslationTasksPage({super.key});

  @override
  State<TranslationTasksPage> createState() => _TranslationTasksPageState();
}

class _TranslationTasksPageState extends State<TranslationTasksPage> {
  var filter = _Filter.all;

  @override
  Widget build(BuildContext context) {
    var tasks = TranslationTasks.instance;
    return ListenableBuilder(
      listenable: tasks,
      builder: (context, _) {
        var list = tasks.tasks;
        var shown = list.where(filter.matches).toList();
        return Scaffold(
          appBar: Appbar(
            title: Text('翻译任务'.tl),
            actions: [
              if (list.any((task) => task.isFailed))
                Tooltip(
                  message: '重试所有失败'.tl,
                  child: IconButton(
                    icon: const Icon(Icons.replay),
                    onPressed: tasks.retryAllFailed,
                  ),
                ),
              if (list.any((task) => !task.isActive))
                Tooltip(
                  message: '清除已完成'.tl,
                  child: IconButton(
                    icon: const Icon(Icons.clear_all),
                    onPressed: tasks.clearFinished,
                  ),
                ),
            ],
          ),
          body: Column(
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Row(
                  children: [
                    for (var f in _Filter.values)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: ChoiceChip(
                          label: Text(
                              '${f.label.tl} (${list.where(f.matches).length})'),
                          selected: filter == f,
                          onSelected: (_) => setState(() => filter = f),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: shown.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            filter.empty.tl,
                            textAlign: TextAlign.center,
                            style:
                                TextStyle(color: context.colorScheme.outline),
                          ),
                        ),
                      )
                    : ListView(
                        children: [
                          for (var task in shown) _TaskTile(task),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile(this.task);

  final TranslationTask task;

  @override
  Widget build(BuildContext context) {
    var batch = task.batch;
    var progress = '${'成功'.tl} ${batch.succeeded}/${batch.total}';
    if (batch.failed > 0) progress += ', ${'失败'.tl}: ${batch.failed}';
    String state;
    if (task.isWaiting) {
      state = '等待中'.tl;
    } else if (task.isRunning) {
      state = '正在翻译'.tl;
    } else if (batch.stopReason != null) {
      state = '${'翻译连续失败, 已停止'.tl}: ${batch.stopReason}';
    } else {
      state = '已完成'.tl;
    }
    return ListTile(
      title: Text(
        task.chapter == null ? task.title : '${task.title} · ${task.chapter}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: batch.total == 0 ? 1 : batch.finished / batch.total,
          ),
          const SizedBox(height: 4),
          Text('$state  $progress',
              maxLines: 3, overflow: TextOverflow.ellipsis),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (task.isFailed)
            Tooltip(
              message: '重试'.tl,
              child: IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () => TranslationTasks.instance.retry(task),
              ),
            ),
          Tooltip(
            message: task.isActive ? '取消'.tl : '移除'.tl,
            child: IconButton(
              icon: Icon(task.isActive ? Icons.close : Icons.delete_outline),
              onPressed: () => TranslationTasks.instance.cancel(task),
            ),
          ),
        ],
      ),
    );
  }
}
