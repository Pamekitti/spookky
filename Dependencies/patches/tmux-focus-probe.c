#define notify_client probe_notify_client
#define server_client_handle_key probe_handle_key
#define window_update_focus probe_window_update_focus
#include "tty-keys.c"
#include <assert.h>

static int updates;
static int notifications;

void probe_notify_client(const char *name, struct client *client)
{
	(void)name;
	(void)client;
	notifications++;
}

int probe_handle_key(struct client *client, struct key_event *event)
{
	(void)client;
	(void)event;
	return 0;
}

void probe_window_update_focus(struct window *window)
{
	assert(window != NULL);
	updates++;
}

int main(void)
{
	struct client client = { 0 };
	struct session session = { 0 };
	struct winlink link = { 0 };
	struct window window = { 0 };
	struct tty *tty = &client.tty;
	int phase;

	client.name = "focus-regression";
	tty->client = &client;
	tty->in = evbuffer_new();
	assert(tty->in != NULL);
	tty_keys_add(tty, "\033[I", KEYC_FOCUS_IN);
	tty_keys_add(tty, "\033[O", KEYC_FOCUS_OUT);
	for (phase = 0; phase < 3; phase++) {
		client.session = phase == 0 ? NULL : &session;
		session.curw = phase == 2 ? &link : NULL;
		link.window = &window;
		evbuffer_add(tty->in, "\033[I", 3);
		assert(tty_keys_next(tty) == 1);
		assert(client.flags & CLIENT_FOCUSED);
		evbuffer_add(tty->in, "\033[O", 3);
		assert(tty_keys_next(tty) == 1);
		assert(!(client.flags & CLIENT_FOCUSED));
		assert(EVBUFFER_LENGTH(tty->in) == 0);
	}
	assert(updates == 2);
	assert(notifications == 6);
	tty_keys_free(tty);
	evbuffer_free(tty->in);
	puts("Six focus events passed across detached, windowless and attached clients.");
	return 0;
}
