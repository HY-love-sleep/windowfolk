// 不导入 Testing：`Testing.Attachment` 与 `WindowfolkCore.Attachment` 同名，
// 在同时导入两者的测试文件中无法直接写出后者。测试文件改用这里的别名。
@testable import WindowfolkCore

typealias CoreAttachment = Attachment
