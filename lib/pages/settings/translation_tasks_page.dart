import 'package:flutter/material.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/page_translation/translation_tasks.dart';
import 'package:pica_comic/tools/translations.dart';

/// The chapters being translated in the background, and how the last ones
/// went.
class TranslationTasksPage extends StatelessWidget {
  const TranslationTasksPage({super.key});

  @override
  Widget build(BuildContext context) {
    var tasks = TranslationTasks.instance;
    return ListenableBuilder(
      listenable: tasks,
      builder: (context, _) {
        var list = tasks.tasks;
        return Scaffold(
          appBar: Appbar(
            title: Text('翻译任务'.tl),
            actions: [
              if (list.any((task) => !task.isRunning))
                Tooltip(
                  message: '清除已完成'.tl,
                  child: IconButton(
                    icon: const Icon(Icons.clear_all),
                    onPressed: tasks.clearFinished,
                  ),
                ),
            ],
          ),
          body: list.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      '没有翻译任务。在阅读器里点翻译按钮后, 本章会在后台翻译, 退出漫画也会继续。'.tl,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.colorScheme.outline),
                    ),
                  ),
                )
              : ListView(
                  children: [
                    for (var task in list) _TaskTile(task),
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
    var progress = '${batch.finished} / ${batch.total}';
    if (batch.failed > 0) progress += ', ${'失败'.tl}: ${batch.failed}';
    String state;
    if (task.isRunning) {
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
      trailing: Tooltip(
        message: task.isRunning ? '取消'.tl : '移除'.tl,
        child: IconButton(
          icon: Icon(task.isRunning ? Icons.close : Icons.delete_outline),
          onPressed: () => TranslationTasks.instance.cancel(task),
        ),
      ),
    );
  }
}
