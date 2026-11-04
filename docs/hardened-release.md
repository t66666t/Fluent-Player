# Android / Windows 加固发布

本流程使用构建期混淆、符号分离和发布内容检查，不增加运行时加壳、反调试或接口解密逻辑。

## 构建

在项目根目录的 PowerShell 执行：

```powershell
.\scripts\build_hardened_release.ps1 -ReleaseId 20261023-hardened-02
```

每次使用新的 ReleaseId；正式 APK 使用现有 android/key.properties 对应的签名。
脚本会在构建前记录旧 APK 证书，构建后核对签名一致性。没有签名配置时构建必须失败，不能以开发签名冒充正式发布。

交付目录是 `dist/hardened/<ReleaseId>/android` 和 `dist/hardened/<ReleaseId>/windows/Release`。
Windows 必须交付完整 Release 文件夹，不能只交付 EXE。
SHA256SUMS.txt 为发布文件的校验清单。

## 私有材料

`.artifacts/hardened-release/<ReleaseId>/` 包含 Dart 混淆映射、分离符号、R8 映射、构建日志、检查报告和构建前的数据保护快照。
这些材料不能随安装包上传，也不要提供给逆向评估方。保留这些材料才能还原混淆后的崩溃堆栈。
该目录及公开构建产物目录均已加入 Git 忽略规则。

## 实际操作

1. 运行发布内容检查器的回归测试及下载、凭据、网盘、本地翻译、后台播放和局域网同步相关的现有测试。
2. 在 Windows 构建前备份并校验现有数据，保留应用身份，使用 Release、Dart 混淆和调试符号分离。
3. 独立翻译进程通过自己的 Dart AOT 构建参数单独混淆及分离符号。
4. Android 使用 Release、Dart 混淆、R8 和资源压缩；Python 字节码编译失败直接停止构建。
5. 校验 APK 签名和非调试 Manifest，核对 AudioService 反射字段、Python 回调及 ASR JNI 的 R8 映射。
6. 根据这次 CMake 安装清单及生成的插件/FFI 运行库清单，将运行必需文件复制到全新的 Windows Release 文件夹；检查 PE 导入的 DLL 依赖，忽略构建目录中的下载、用户数据和旧安装器。
7. 检查 APK 和 Windows 文件夹中的源码、密钥特征、个人数据文件、内嵌调试段，以及必要的模型目录和 OCR/ONNX 运行库。GnuTLS 公开密码学自测样本只有在 DLL 和自测样本指纹均符合已核对的上游内容时才获豁免，其他凭据规则仍然生效。
8. 所有检查通过后生成校验清单。失败的输出目录不能作为通过验证的发布包。

`-SkipWindowsBuild` / `-SkipAndroidBuild` 只用于同一个 ReleaseId 的构建恢复，必须保留对应的私有映射材料。
脚本拒绝覆盖已有交付目录。任何失败目录都应保留检查后另换 ReleaseId，避免把旧产物误作新版本。
如果构建和复制已完成、只需重新检查，可使用 `-VerifyOnly -ReleaseId <原编号>`；这不会重新构建或覆盖安装包。

## 边界和实机验证

名称混淆不会加密接口地址、资源或 Python 字节码，也不能防止复制整个编译产物。
第三方接口的访问权限仍由第三方平台决定。此流程不改变网络协议、离线功能、用户登录或播放算法。

自动测试通过不代表全部平台功能和性能已经实测。发布前仍需在 Android 真机检查冷启动、登录、WebView、下载暂停恢复、后台播放和通知、字幕、OCR/ASR、CPU/GPU 翻译及覆盖更新。
Windows 需要检查完整 Release 文件夹中的启动、播放、下载、独立进程和 GPU/CPU 回退。
脚本会自动验证混淆后的翻译子进程启动、原生库加载、JSON 通信及正常退出，但这不等同于已用真实模型验证推理。
性能对比应采用同一设备、同一媒体和模型、多次交错测试；不能把本流程的构建成功描述为“绝对零性能影响”。

## 下次发布提示词

> 请按 docs/hardened-release.md 和 scripts/build_hardened_release.ps1 的流程，构建 Android 正式签名 APK 与 Windows Release 文件夹。保持功能、应用身份和升级兼容性，保护已有用户数据。主程序与独立翻译进程都要混淆，调试符号和映射只作私有归档。验证最终包的签名、反射/JNI/Python 回调、运行库及敏感文件，执行相关回归测试，记录实测范围和未验证项目。交付干净产物与校验清单，不要把符号、源码、会话配置或用户数据放入交付目录。
