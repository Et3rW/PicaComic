part of pica_settings;

class NhSettings extends StatefulWidget {
  const NhSettings(this.popUp, {super.key});

  final bool popUp;

  @override
  State<NhSettings> createState() => _NhSettingsState();
}

class _NhSettingsState extends State<NhSettings> {

  String baseUrl = "https://nhentai.net";

  void deleteAllCookie() async {
    final cookieJar = SingleInstanceCookieJar.instance!;
    var cookies = cookieJar.loadForRequest(Uri.parse(baseUrl));
    if (cookies.isEmpty) {
      showToast(message: "cookie 为空".tl);
      return;
    } else {
      var title = "${"确认删除".tl}?";
      var msg = "${"删除全部".tl}(${cookies.length}) nhentai cookie\n${"删除后需重新登录".tl}\n";
      showConfirmDialog(App.globalContext!, title, msg, () {
        NhentaiNetwork().logged = false;
        cookieJar.deleteUri(Uri.parse(baseUrl));
        var source = ComicSource.find('nhentai')!;
        source.data["account"] = null;
        source.saveData();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          title: Text("nhentai".tl),
        ),
        ListTile(
          leading: const Icon(Icons.delete_forever),
          title: Text("${"删除".tl} cookie"),
          onTap: () => deleteAllCookie(),
          trailing: const Icon(Icons.arrow_right),
        ),
        ValueListenableBuilder(
          valueListenable: NhentaiTagSettings.changes,
          builder: (context, _, __) => ListTile(
            leading: const Icon(Icons.layers_outlined),
            title: Text("点标签时叠加到当前标签".tl),
            subtitle: Text("在分类或标签页里打开漫画, 再点标签会和页面上的标签一起搜索, 最多 @n 个"
                .tlParams({"n": "$nhentaiTagStackLimit"})),
            trailing: Switch(
              value: NhentaiTagSettings.stackEnabled,
              onChanged: (v) => NhentaiTagSettings.setStackEnabled(v),
            ),
            onTap: () => NhentaiTagSettings.setStackEnabled(
                !NhentaiTagSettings.stackEnabled),
          ),
        ),
        ValueListenableBuilder(
          valueListenable: NhentaiTagSettings.changes,
          builder: (context, _, __) {
            var count = NhentaiTagSettings.defaultExcludes.terms.length;
            return ListTile(
              leading: const Icon(Icons.block),
              title: Text("默认排除的标签".tl),
              subtitle: Text(count == 0
                  ? "未设置".tl
                  : "已排除 @n 个标签".tlParams({"n": "$count"})),
              trailing: const Icon(Icons.arrow_right),
              onTap: () => context.to(() => const NhentaiDefaultExcludesPage()),
            );
          },
        ),
      ],
    );
  }
}