---
title: Mở khóa Mac bằng vân tay trên tinyTouch
description: Khả năng giữ ESP32-S3 và cảm biến hiện có để mở phiên macOS mà không gõ PIN qua USB.
---

# Mở khóa Mac bằng vân tay trên tinyTouch

Ngày 19 tháng 11 năm 2026. Mục tiêu là để tinyTouch cắm sẵn, khóa phiên đang dùng, chạm đúng một lần rồi quay lại desktop. Ô đăng nhập không nhận ký tự qua bàn phím USB. Nếu còn phải rút cắm USB, chọn tài khoản, bấm OK hoặc chạm lại thì chưa đạt trải nghiệm này. Mở phiên sau khi khởi động lại và mở đĩa FileVault là hai trường hợp khác.

## Những gì đã kiểm tra trên thiết bị

| Quan sát | Kết quả |
| --- | --- |
| Máy đang kết nối | Apple silicon, macOS 27.0, build 26A428 |
| Phản hồi `STATUS` từ tinyTouch | Firmware 0.1.39, protocol 6, `mode=piv`, `piv_touch_active=on`, `piv_visible=no` lúc đọc |
| Tự nhập | `piv_auto_type=1`, `piv_delay_ms=800`, `typing_delay_ms=1`, `submit_enter=1` |
| HID khi nghỉ | macOS thấy usage page `0x0001`, usage `0x0006` (bàn phím). Không có collection FIDO `0xF1D0`. |
| Đầu đọc PC/SC | Liệt kê thành công. Không thấy đầu đọc tên tinyTouch khi thẻ đang ẩn. |

Trong firmware, `handle_fingerprint_match` cấp quyền dùng thẻ sau khi nhận vân tay đúng. Nếu bật tự nhập, nó gọi `type_ascii(piv_pin, ...)`. Khoảng chờ 800 ms bắt đầu sau khi Mac chọn ứng dụng PIV và USB sẵn sàng. Giá trị này không đo thời gian từ lúc chạm tới khi mở phiên. Mã liên quan nằm trong `firmware/tiny_touch_unified/main/touch_pin_hid.c`. [Tùy chọn PIV và thời điểm gõ PIN](./configuration.md#delay-before-pin-entry)

## Hướng có phần mềm mở khóa Mac được nhà cung cấp mô tả

Giữ ESP32-S3 và cảm biến ZW111. Bổ sung chức năng khóa USB FIDO2 vào firmware. Khi Mac yêu cầu xác thực, thiết bị đối chiếu ngón tay và dùng khóa riêng để ký yêu cầu. Phần mềm đăng nhập trên Mac phải biết dùng kết quả đó để mở phiên. Dự án Pico Fido đã có CTAP2 và phần mở rộng `hmac-secret` trên dòng phần cứng có ESP32-S3. Đây là mã tham khảo cho phần giao tiếp. Việc tích hợp cảm biến ZW111, bảo vệ thông tin đăng ký và kiểm tra trên bo tinyTouch là công việc riêng. [Đặc tả CTAP](https://fidoalliance.org/specs/fido-v2.2-ps-20250714/fido-client-to-authenticator-protocol-v2.2-ps-20250714.html) · [Pico Fido](https://github.com/librekeys/pico-fido)

YubiOn FIDO Logon có client cho Apple silicon và liệt kê macOS Golden Gate trong các hệ điều hành hỗ trợ. Họ mô tả cách xác thực bằng khóa USB ở màn hình khóa. Với khóa sinh trắc tương thích đã đăng ký PIN và vân tay, tài liệu đăng ký mô tả việc dùng vân tay thay cho nhập PIN. Lần đầu dùng khóa để đăng nhập, người dùng nhập mật khẩu tài khoản Mac. Client dùng khóa dẫn xuất qua `hmac-secret` để bảo vệ bản lưu mật khẩu và dùng lại sau khi xác thực FIDO thành công. Sau khi đổi mật khẩu Mac, phải nhập lại mật khẩu mới. [Hệ điều hành hỗ trợ](https://fl.yubion.com/guide/en/introduction/system_requirements/) · [Đăng ký khóa và xác minh vân tay](https://fl.yubion.com/guide/en/users_manual_macos/setup/assign_credential/assign_credential_securitykey/) · [Cách client mở phiên và bảo vệ mật khẩu](https://www.yubion.com/en/blog/yubion-fido-logon-macos-guide/)

Mac vẫn hiển thị hộp thoại hệ thống khi mở khóa. Nhà cung cấp cho biết người dùng không cần bấm nút OK của khung macOS trong khi client đang xác thực. Hướng dẫn bắt đầu bằng việc kết nối khóa. Khả năng nhận một lần chạm khi tinyTouch đã cắm từ trước cần thử riêng. YubiOn nêu khóa được FIDO Alliance chứng nhận và công bố danh sách đã thử. TinyTouch không có tên trong danh sách đó. Còn phải xác nhận client chấp nhận thiết bị tự phát triển khi đăng ký, kể cả nếu thiết bị vượt qua thử nghiệm FIDO trong trình duyệt. [Giao diện màn hình khóa](https://fl.yubion.com/guide/en/users_manual_macos/notes/screen_lock_restrictions/) · [Quy trình mở phiên](https://fl.yubion.com/guide/en/users_manual_macos/pc_logon/logon/logon_securitykey/) · [Loại khóa nhà cung cấp hỗ trợ](https://fl.yubion.com/guide/en/introduction/before_started/)

## Kết quả thử FIDO2 trên Mac

Ngày 19 tháng 11 năm 2026, macOS 27.0 báo tinyTouch `303a:4001` ở HID usage `0x0001/0x0006`. Thư viện `python-fido2` đếm được **0** khóa USB FIDO. Cùng lúc đó, CLI đọc được `sensor=ready`, `fingerprints=4`, `firmware=0.1.39`, `mode=piv`. Firmware đang chạy chưa có giao diện để Mac gửi yêu cầu CTAP. Chưa có lần mở màn hình khóa bằng FIDO2 trên thiết bị thật.

| Phép thử | Kết quả |
| --- | --- |
| Chrome với khóa CTAP2.1 ảo | Đăng ký và xác minh chữ ký thành công với `userVerification=required`. Kết quả PRF dài 32 byte, lặp lại với cùng đầu vào và khác nhau giữa hai đầu vào. Yêu cầu mới từ chối phản hồi cũ. Khi tắt xác minh người dùng, Chrome không trả về xác thực hợp lệ. |
| Pico FIDO `74a3a29` | Build được cho ESP32-S3. `GetInfo` của bản mô phỏng có `hmac-secret`, không công bố `uv` tích hợp. Với PIN dùng riêng cho mô phỏng, cùng phép thử đăng ký, hai chữ ký và PRF đều đạt. Chưa tích hợp cảm biến vân tay tinyTouch. |
| ESP32-FIDO2 Lab `7489d3a` | Build được cho ESP32-S3 và năm bài test native đạt. Bản tham khảo AtomS3U dùng nút nhấn cho thao tác hiện diện, PIN cho xác minh người dùng và chỉ công bố extension `credProtect`. |

Chạy `uv run --script scripts/try-fido2.py` ở thư mục gốc để thử thiết bị thật. Script chỉ mở giao diện FIDO nhận diện là tinyTouch. Sau khi đọc `GetInfo`, nó chỉ bắt đầu đăng ký credential thử nếu thiết bị báo `uv=true` và `hmac-secret`. Script yêu cầu xác minh trên thiết bị và dùng thư viện FIDO kiểm tra chữ ký. Có thể chạy đối chứng với Chrome đã cài bằng `uv run --script tests/fido2_browser_trial.py`. Khóa ảo chỉ tồn tại trong phiên trình duyệt thử.

Hai bản build dùng sơ đồ flash khác tinyTouch. Ví dụ, vùng dữ liệu `part0` của Pico FIDO bắt đầu ở `0x200000`, chồng lên phần cuối slot OTA thứ hai, metadata OTA và vùng recovery của tinyTouch. Cần tích hợp FIDO và cảm biến vào firmware dùng đúng bảng phân vùng của tinyTouch trước khi thử trên bo đang giữ PIV. Để xác nhận mục tiêu cuối cùng, cần quan sát Mac đang khóa với tinyTouch cắm sẵn và ngón tay thật. Hướng dẫn YubiOn bắt đầu bằng thao tác kết nối khóa ở màn hình khóa. [Pico FIDO ở phiên bản đã thử](https://github.com/librekeys/pico-fido/tree/74a3a29ca018b1db262ccc6a5caf5bc1af425d06) · [ESP32-FIDO2 Lab ở phiên bản đã thử](https://github.com/itres-labs/esp32-fido2-lab/tree/7489d3a2c7780c6c973707dafc179ecffb313b51) · [Hướng dẫn mở khóa của YubiOn](https://fl.yubion.com/guide/en/users_manual_macos/pc_logon/logon/logon_securitykey/)

## Phép thử quyết định

1. Xác nhận chính sách đăng ký của client đối với khóa tự phát triển. Tài liệu hiện có chưa xác nhận tinyTouch đủ điều kiện. Đây là điểm nên giải quyết trước khi đầu tư chuyển firmware.
2. Nếu client chấp nhận loại khóa này, thử một bản firmware dành cho thử nghiệm trên nền phần cứng tinyTouch. Phép thử FIDO phải yêu cầu xác minh người dùng. Một ngón đã đăng ký mới được phép tạo phản hồi có cờ `UV`. Kiểm tra từ chối khi dùng ngón chưa đăng ký và kiểm tra `hmac-secret` hoạt động với chính thông tin xác thực vừa đăng ký. [Xác minh người dùng và các phần mở rộng CTAP](https://fidoalliance.org/specs/fido-v2.2-ps-20250714/fido-client-to-authenticator-protocol-v2.2-ps-20250714.html)
3. Đăng ký khóa với client trên một máy hoặc bản cài macOS dành cho thử nghiệm. Giữ thiết bị cắm sẵn. Sau khi khóa phiên, kiểm tra rằng ngón lạ không mở được, một lần chạm ngón đúng đưa về đúng phiên và USB không phát ký tự bàn phím. Thử màn hình đang sáng và sau khi máy ngủ riêng biệt. Khi cảm biến bị rút, người dùng vẫn cần đăng nhập được bằng phương thức dự phòng đã chọn. Hướng dẫn của nhà cung cấp phân biệt mở phiên đang khóa với xác thực FileVault lúc khởi động. [Giới hạn giao diện khi mở khóa](https://fl.yubion.com/guide/en/users_manual_macos/notes/screen_lock_restrictions/) · [FileVault và mở phiên sau khi ngủ](https://fl.yubion.com/guide/en/users_manual_macos/notes/filevault/)

## Khả năng giữ PIV

Apple có API để đầu đọc tương thích thực hiện xác minh PIN qua phần cứng. Với tinyTouch, descriptor CCID trong mã nguồn dài 54 byte và trường `bPINSupport` ở offset 52 bằng 0. Bộ xử lý trong `firmware/tiny_touch_unified/main/usb_ccid.c` cũng chưa xử lý lệnh `PC_to_RDR_Secure`. Vì vậy, tắt `piv_auto_type` chưa cung cấp kênh thay thế cho thao tác mà giao diện macOS yêu cầu. [CryptoTokenKit và nhập PIN trên đầu đọc](https://developer.apple.com/documentation/cryptotokenkit/tktokensmartcardpinauthoperation/apdutemplate) · [Đặc tả USB CCID](https://www.usb.org/sites/default/files/DWG_Smart-Card_CCID_Rev110.pdf)

Chỉ nên coi đây là hướng có thể dùng độc lập với client FIDO sau khi xác nhận màn hình khóa thực sự yêu cầu thao tác trên đầu đọc và chấp nhận xác minh sinh trắc của thẻ. NIST có mô tả xác minh sinh trắc trên thẻ trong PIV. API nhập PIN trên đầu đọc và tiêu chuẩn sinh trắc giải quyết hai câu hỏi khác nhau. Một trong hai tài liệu riêng lẻ chưa xác lập khả năng mở phiên trên macOS. Hai bài kiểm thử mô phỏng USB/PIV của dự án đã đạt. Chúng kiểm tra hiển thị thẻ và vận chuyển gói tin. Lượt khảo sát này chưa thử mở khóa thật, chưa cài client và chưa nạp firmware. [Apple về thẻ thông minh trên Mac](https://support.apple.com/en-ie/guide/deployment/depc47f60521/web) · [NIST FIPS 201-3](https://pages.nist.gov/FIPS201/FIPS201.html)
