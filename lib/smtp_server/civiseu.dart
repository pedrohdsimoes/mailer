import '../smtp_server.dart';

SmtpServer civiseu(String username, String password) =>
    SmtpServer('mail.civiseu.pt', username: username, password: password);
