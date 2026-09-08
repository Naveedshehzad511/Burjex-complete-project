from django.shortcuts import render


class Custom404Middleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        response = self.get_response(request)
        if response.status_code != 404:
            return response

        path = request.path_info or ""
        if path.startswith(("/static/", "/media/", "/api/")):
            return response

        accept = request.META.get("HTTP_ACCEPT", "")
        if accept and "text/html" not in accept and "*/*" not in accept:
            return response

        return render(request, "404.html", status=404)
