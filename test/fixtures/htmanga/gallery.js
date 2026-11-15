
document.writeln("	<script type=\"text/javascript\">");
document.writeln("		var sns_sys_id = '';");
document.writeln("		var sns_view_point_token = '';");
document.writeln("		var hash = window.location.hash;");
document.writeln("		if(!hash){");
document.writeln("			hash = 0;");
document.writeln("		}else{");
document.writeln("			hash = parseInt(hash.replace(\"#\",\"\")) - 1;");
document.writeln("		}");
document.writeln("		var fast_img_host=\"\";");
document.writeln("		var imglist = [{ url: fast_img_host+\"//img5.qy0.ru/data/4049/29/01.jpg?verify=1794744000-y5FxH-151CyuYKVrlF6seBfxBJIoxZwAKS1D6B2IaEo\", caption: \"[01]\"},{ url: fast_img_host+\"//img5.qy0.ru/data/4049/29/02.jpg?verify=1794744000-Z2VuUa8sl6OasohWlk8gH3jAo4vdJFsrSOAS-zQAylw\", caption: \"[02]\"},{ url: fast_img_host+\"//img5.qy0.ru/data/4049/29/03.jpg?verify=1794744000-YKIKlHkHETnq-TT36BM6faqOUPMQH7tOpht4JpMOLAQ\", caption: \"[03]\"}];");
document.writeln("");
document.writeln("		$(function(){");
document.writeln("			imgscroll.beLoad($(\"#img_list\"),imglist,hash);");
document.writeln("		});");
document.writeln("	</script>");
