import 'dart:io';

bool isNetworkFailure(Object error) =>
    error is SocketException || error is HttpException;
