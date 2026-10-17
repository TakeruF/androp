# 发布与隐私

简体中文 · [English](publication.en.md)

仓库作为源码项目准备，兼容报告仅机型／软件／结果，不含个人raw抓包。公开仓库／发行前检查tracked文件 **及Git历史** 的姓名、邮箱、home路径、序列号、私设备名、SSID、地址、凭据、证书身份；后续删文件不清旧历史。

不想全局个人Git身份进commit时用repo-local设置。初始提交为anDrop contributors和不可投递example.invalid；GitHub仍显示owner，账号活动可关联，公开commit签名和发行证书也能标识本人。

真实日志／私截图／抓包／fixtures／构建中间产物放ignored。仅审查过的 `dist/<version>/public/` DMG、签名appcast、校验和是发行资产，不上传相邻private目录。docs/images为审查过的虚构UI例外，按该目录说明只用虚构数据重生。gitignore不是秘密检测器，显式检查staged，仓库外已有私有试验产物也不能当发行资产。

源码无固定个人Computer Name，运行时按系统名字并向附近广播，见[使用](usage.md)。ThirdPartyNotices上游作者姓名／版权需保留，是归属而非owner私信息。官方logo来源与独立权利在[品牌素材](../Resources/BrandLogos/README.md)，也应发布审查，源码许可不授予logo权利。
