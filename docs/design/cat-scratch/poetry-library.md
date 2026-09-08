# 内置空白卡诗句库

内置 2000 组去重的古诗短句，每组为两行等长五言或七言，保留原先八组。卡面仅显示诗句和「偶得一句」，继续使用本地文楷。正文编译为 Dart 常量，离线可用；作者、篇名、原文与来源定位仅保留在本目录的 poetry-library.json，不打入 App。

数据来源为 https://github.com/chinese-poetry/chinese-poetry ，固定提交 b8594f81a89752241442f2ce267d6f66f96704ee 的《唐诗三百首》《千家诗》和水墨唐诗数据。原诗为公版作品，数据集 MIT 声明随包放在 assets/poetry/LICENSE.txt。manifest 记录原文件 SHA-256；三个未在候选中匹配的既有条目标记 legacy-approved。

提取完整相邻诗句，不拼接、不改写、不引入现代译文。使用 OpenCC t2s 转简体，筛选纯汉字五言/七言和句读，排除注释、疑似错字、去标点重复及仅一字不同的近重复候选。已对全部正文核对当前文楷字体 cmap。来源元数据沿用选集记录，并非逐条人工校勘；遇到源数据异文可依据 original 和 locator 追溯。

生成与检查（Python 3 标准库，无运行时网络依赖）：

```sh
python3 tool/generate_blank_card_poems.py
python3 tool/generate_blank_card_poems.py --check
```

可加 --verbose 查看路径与生成文件字节数。源清单是维护入口，生成器检查精确数量、正文去重和两行格式；Flutter 测试同时验证源清单与编译常量一致、2000 条均可被选择及紧凑卡面排版。

诗句仍使用独立于奖品和材质的 serial 派生随机种子。同一库版本、同一 serial 显示稳定；扩充库后旧 serial 对应诗句可能改变。中奖概率及空白材质 30/30/20/15/5 比例不变，诗句不会新增收藏。
